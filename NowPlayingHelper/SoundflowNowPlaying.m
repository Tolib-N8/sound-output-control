// SoundflowNowPlaying — bridge to the private MediaRemote framework.
//
// Since macOS 15.4 MediaRemote only answers Apple-signed clients, so Soundflow can't read
// "Now Playing" itself. This library is loaded into /usr/bin/perl (Apple-signed, no library
// validation) by nowplaying.pl, which calls sf_run(). It then:
//   • writes one JSON object per line to stdout whenever the now-playing state changes;
//   • reads commands from stdin: toggle | play | pause | next | previous | seek <seconds>.
// The process exits when stdin closes (Soundflow quit).

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

enum { kMRPlay = 0, kMRPause = 1, kMRTogglePlayPause = 2, kMRNextTrack = 4, kMRPreviousTrack = 5 };

static MRRegisterFn MRRegister;
static MRGetInfoFn MRGetInfo;
static MRGetBoolFn MRGetIsPlaying;
static MRGetPIDFn MRGetPID;
static MRSendCommandFn MRSendCommand;
static MRSetElapsedFn MRSetElapsed;

static NSString *lastArtworkKey;
static BOOL refreshScheduled;

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    @synchronized ([NSFileHandle class]) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static id jsonValue(id value) {
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSDate.class]) return @([(NSDate *)value timeIntervalSince1970]);
    return nil;
}

/// Collects info, playing state and source PID, then emits a single event.
static void refresh(void) {
    MRGetInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        MRGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            MRGetPID(dispatch_get_main_queue(), ^(int pid) {
                NSMutableDictionary *event = [NSMutableDictionary dictionary];
                event[@"type"] = @"state";
                event[@"playing"] = @(playing);
                event[@"pid"] = @(pid);
                NSDictionary *keys = @{
                    @"kMRMediaRemoteNowPlayingInfoTitle": @"title",
                    @"kMRMediaRemoteNowPlayingInfoArtist": @"artist",
                    @"kMRMediaRemoteNowPlayingInfoAlbum": @"album",
                    @"kMRMediaRemoteNowPlayingInfoDuration": @"duration",
                    @"kMRMediaRemoteNowPlayingInfoElapsedTime": @"elapsed",
                    @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @"rate",
                    @"kMRMediaRemoteNowPlayingInfoTimestamp": @"timestamp",
                    @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier": @"itemId",
                };
                [keys enumerateKeysAndObjectsUsingBlock:^(NSString *source, NSString *target, BOOL *stop) {
                    id value = jsonValue(info[source]);
                    if (value) event[target] = value;
                }];

                NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSString *artworkKey = nil;
                if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
                    id identifier = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
                    artworkKey = [NSString stringWithFormat:@"%@-%lu-%lu", identifier ?: @"", (unsigned long)artwork.length,
                                  (unsigned long)artwork.hash];
                    event[@"artworkId"] = artworkKey;
                    // Images are large: only send them when they change.
                    if (![artworkKey isEqualToString:lastArtworkKey]) {
                        event[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                    }
                }
                lastArtworkKey = artworkKey;
                emit(event);
            });
        });
    });
}

/// Notifications arrive in bursts; coalesce them into one refresh.
static void scheduleRefresh(void) {
    if (refreshScheduled) return;
    refreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refreshScheduled = NO;
        refresh();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    Boolean ok = true;
    if ([command isEqualToString:@"toggle"]) ok = MRSendCommand(kMRTogglePlayPause, nil);
    else if ([command isEqualToString:@"play"]) ok = MRSendCommand(kMRPlay, nil);
    else if ([command isEqualToString:@"pause"]) ok = MRSendCommand(kMRPause, nil);
    else if ([command isEqualToString:@"next"]) ok = MRSendCommand(kMRNextTrack, nil);
    else if ([command isEqualToString:@"previous"]) ok = MRSendCommand(kMRPreviousTrack, nil);
    else if ([command isEqualToString:@"seek"] && parts.count > 1) MRSetElapsed(parts[1].doubleValue);
    else if ([command isEqualToString:@"refresh"]) { /* just re-emit below */ }
    else ok = false;
    emit(@{@"type": @"ack", @"command": command ?: @"", @"ok": @(ok)});
    scheduleRefresh();
}

static void readCommands(void) {
    [NSThread detachNewThreadWithBlock:^{
        char buffer[256];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length == 0) continue;
            dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
        }
        exit(0); // Soundflow went away.
    }];
}

/// Entry point, installed as a Perl XSUB (its arguments are ignored).
__attribute__((visibility("default"))) void sf_run(void *perl, void *cv) {
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        MRRegister = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRGetInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        MRGetIsPlaying = (MRGetBoolFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        MRSendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        MRSetElapsed = (MRSetElapsedFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
        if (!MRRegister || !MRGetInfo || !MRGetIsPlaying || !MRGetPID || !MRSendCommand || !MRSetElapsed) {
            emit(@{@"type": @"error", @"message": @"MediaRemote unavailable"});
            exit(2);
        }

        MRRegister(dispatch_get_main_queue());
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
                                 @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                        usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
        }
        emit(@{@"type": @"ready"});
        readCommands();
        refresh();
        // Elapsed time drifts with seeks the notifications don't always report; poll gently too.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ refresh(); });
        dispatch_resume(timer);
        CFRunLoopRun();
    }
}
