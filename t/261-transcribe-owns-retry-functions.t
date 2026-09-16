use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-261: retry_failed_transcription/auto_retry_failed_transcriptions
# were an organizational mismatch in D2TG::Download.pm - transcription
# retry belongs with the transcription domain, not the file-download
# module. TGT-263 then moved them one step further, out of
# D2TG::Transcribe itself and into D2TG::Transcribe::Retry (see
# t/263-transcribe-retry-module.t for that ownership proof) - this file
# now only proves the original TGT-261 claim that still holds:
# D2TG::Download no longer defines either function. The deep
# behavioral coverage for both functions already exists in
# t/237/245/246/248/249 - updated in TGT-263 to call the new location.
require D2TG::Download;

ok( !D2TG::Download->can('retry_failed_transcription'), 'D2TG::Download no longer defines retry_failed_transcription' );
ok( !D2TG::Download->can('auto_retry_failed_transcriptions'), 'D2TG::Download no longer defines auto_retry_failed_transcriptions' );

# D2TG::Download's own genuine concern (download retries) is untouched.
can_ok( 'D2TG::Download', 'retry_failed_download' );
can_ok( 'D2TG::Download', 'auto_retry_failed_downloads' );

done_testing();
