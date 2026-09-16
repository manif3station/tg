use strict;
use warnings;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-263: retry_failed_transcription/auto_retry_failed_transcriptions
# (moved into D2TG::Transcribe by TGT-261) are their own distinct
# concern from the core probe/transcribe/timeout logic - they talk to
# D2TG::Poller::store_write_safe and D2TG::Download::download_file, not
# whisper itself. Extracted into D2TG::Transcribe::Retry, mirroring the
# D2TG::Store::RetryQueue precedent (TGT-257). This proves ownership;
# the deep behavioral coverage for both functions already exists in
# t/237/245/246/248/249, updated in this same ticket to call the new
# location.
require D2TG::Transcribe;
require D2TG::Transcribe::Retry;

can_ok( 'D2TG::Transcribe::Retry', 'retry_failed_transcription' );
can_ok( 'D2TG::Transcribe::Retry', 'auto_retry_failed_transcriptions' );

ok( !D2TG::Transcribe->can('retry_failed_transcription'), 'D2TG::Transcribe no longer defines retry_failed_transcription' );
ok( !D2TG::Transcribe->can('auto_retry_failed_transcriptions'), 'D2TG::Transcribe no longer defines auto_retry_failed_transcriptions' );

# D2TG::Transcribe's own genuine concern (probe/transcribe/timeout) is untouched.
can_ok( 'D2TG::Transcribe', 'transcribe' );
can_ok( 'D2TG::Transcribe', 'select_model' );

done_testing();
