use strict;
use warnings;
use Test::More;

use D2TG::Poller::Dispatch;

# TGT-327 (found via a live JOB-004 improvement hunt): handle_plain_update's
# voice-transcription-failure branch and photo/document-download-failure
# branch both independently implement the identical shape - eval-wrap a
# call to record_failed_X, then on $@ print an ERROR-PREFIX "failed to
# queue for retry too" line to STDERR, else print a NEW-TG-X-FAILED line
# naming the retry command. Structural (can()-based) test only - the
# real behavioral coverage already comes from the existing
# t/237/t/83-style failed-download/failed-transcription tests, which
# assert on the exact stdout/STDERR this helper must keep producing.

can_ok( 'D2TG::Poller::Dispatch', '_queue_failed_and_report' );

done_testing();
