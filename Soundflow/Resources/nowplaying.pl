# Loads the SoundflowNowPlaying bridge into this Apple-signed perl and runs it.
# Usage: /usr/bin/perl nowplaying.pl <path-to-SoundflowNowPlaying.dylib>
use strict;
use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $run = DynaLoader::dl_find_symbol($lib, "sf_run") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::sf_run", $run);
sf_run();
