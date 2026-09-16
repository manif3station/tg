use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-261: retry_failed_transcription/auto_retry_failed_transcriptions
# were an organizational mismatch in D2TG::Download.pm - transcription
# retry belongs with D2TG::Transcribe (which already owns select_model/
# _probe_duration/transcribe), not the file-download module. This
# proves they now live there. The deep behavioral coverage for both
# functions already exists in t/237/245/246/248/249 - updated in this
# same ticket to call the new location - so this file only proves
# where the functions live, not how they behave.
require D2TG::Transcribe;
require D2TG::Download;

can_ok( 'D2TG::Transcribe', 'retry_failed_transcription' );
can_ok( 'D2TG::Transcribe', 'auto_retry_failed_transcriptions' );

ok( !D2TG::Download->can('retry_failed_transcription'), 'D2TG::Download no longer defines retry_failed_transcription' );
ok( !D2TG::Download->can('auto_retry_failed_transcriptions'), 'D2TG::Download no longer defines auto_retry_failed_transcriptions' );

# D2TG::Download's own genuine concern (download retries) is untouched.
can_ok( 'D2TG::Download', 'retry_failed_download' );
can_ok( 'D2TG::Download', 'auto_retry_failed_downloads' );

done_testing();
