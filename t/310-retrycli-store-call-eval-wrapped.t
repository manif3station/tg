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

my $module_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'RetryCli.pm' );
open my $fh, '<', $module_path or die "can't read $module_path: $!";
local $/;
my $source = <$fh>;
close $fh;

like( $source, qr/my \$result = eval \{ \$args\{list\}->\(\) \}/,
    'D2TG::RetryCli::_list_or_die wraps the list coderef call in eval, not called raw' );

like( $source, qr/D2TG::Poller::Safe::classify_store_error/,
    'D2TG::RetryCli uses the shared classifier on a store-call failure' );

like( $source, qr/STORE ERROR: failed_\$args\{label\}s failed - \$reason/,
    'D2TG::RetryCli prints a classified STORE ERROR line on failure' );

done_testing();
