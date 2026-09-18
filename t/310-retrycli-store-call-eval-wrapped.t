use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-310 (found via a scheduled JOB-004 improvement hunt): cli/retry-
# download.pl and cli/retry-transcription.pl's own $store->
# failed_downloads/failed_transcriptions eval-wrap+classify+STORE ERROR
# handling (TGT-293) moved into the new shared lib/D2TG/RetryCli.pm
# (D2TG::RetryCli::_list_or_die) as part of extracting the two scripts'
# duplicated argv-dispatch/retry-loop/reporting skeleton. This is
# t/293-cli-store-calls-eval-wrapped.t's own precedent, redirected at
# the new home of the property it checks - a pure extraction, the
# safety property still holds, just relocated.
#
# TGT-314 (found via a scheduled JOB-004 improvement hunt): the
# classify+print+exit shape itself moved again, out of _list_or_die's
# own body and into a new shared D2TG::Poller::Safe::die_store_error
# helper (collapsing this and 12 other near-identical call sites across
# 7 cli/*.pl scripts into one definition) - _list_or_die now just calls
# that helper with its own op_label instead of inlining
# classify_store_error/print STDERR/exit itself. The classify/print
# assertions below were replaced with a die_store_error call-site
# assertion; die_store_error's own internal shape is covered by
# t/314-die-store-error-helper.t and Safe.pm's own source directly.

my $module_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'RetryCli.pm' );
open my $fh, '<', $module_path or die "can't read $module_path: $!";
local $/;
my $source = <$fh>;
close $fh;

like( $source, qr/my \$result = eval \{ \$args\{list\}->\(\) \}/,
    'D2TG::RetryCli::_list_or_die wraps the list coderef call in eval, not called raw' );

like( $source, qr/D2TG::Poller::Safe::die_store_error\( \$@, "failed_\$args\{label\}s" \) if \$@/,
    'D2TG::RetryCli hands a store-call failure to the shared die_store_error helper, naming its own op label' );

done_testing();
