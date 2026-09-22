use strict;
use warnings;
use Test::More;

use D2TG::Store::RetryQueue;

# TGT-330 (found via a live JOB-004 improvement hunt): has_failed_download
# and has_failed_transcription duplicated the identical existence-check
# shape - SELECT 1 FROM <table> WHERE chat_id/bot_key/message_id LIMIT 1,
# return boolean - differing only in table name. Structural (can()-based)
# test only - the real behavioral coverage already comes from the
# existing has_failed_download/has_failed_transcription tests.

can_ok( 'D2TG::Store::RetryQueue', '_has_failed' );

done_testing();
