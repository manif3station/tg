use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-195 (found via a Codex QA-stage review sweep on TGT-194, after
# TGT-194 incorrectly claimed "all known instances of this bug class
# are now fixed" before this repo-wide sweep was done): cli/approve.pl's
# own approve/is_allowed calls ran unwrapped - a locked/busy database at
# either one died raw, printing the real Perl/DBI exception (which can
# embed the real db_path) to STDERR instead of the same clean, scrubbed
# refusal this project's established pattern provides everywhere else
# (D2TG::Poller::run_once's own is_allowed/add_pending, TGT-165/193).
#
# cli/approve.pl has no injectable seam for a fake D2TG::Store double
# (unlike D2TG::Poller::run_once, an importable function) - a real
# locked-database failure occurring strictly AFTER D2TG::Store->new
# already succeeded is not reliably reproducible black-box via a CLI
# subprocess without fragile timing/concurrency tricks. This is a
# structural/source-inspection regression test instead, matching this
# project's own established precedent for exactly this situation
# (t/104-retry-download-cli-no-raw-path.t, t/88-poller-help-pod-parity.t).

my $script_path = File::Spec->catfile( $Bin, '..', 'cli', 'approve.pl' );
open my $fh, '<', $script_path or die "can't read $script_path: $!";
local $/;
my $source = <$fh>;
close $fh;

like( $source, qr/my \$approved = eval \{ \$store->approve\(/,
    'the approve call is wrapped in eval, not called raw' );
like( $source, qr/my \$allowed = eval \{ \$store->is_allowed\(/,
    'the is_allowed call is wrapped in eval, not called raw' );

my $approve_count  = () = $source =~ /D2TG::Poller::_classify_store_error/g;
is( $approve_count, 2, 'both call sites classify their own failure via D2TG::Poller::_classify_store_error - not the raw exception' );

unlike( $source, qr/if\s*\(\s*\$store->approve\(/,
    'approve is never called directly inside a conditional - only via the eval-captured $approved variable' );
unlike( $source, qr/if\s*\(\s*\$store->is_allowed\(/,
    'is_allowed is never called directly inside a conditional - only via the eval-captured $allowed variable' );

like( $source, qr/STORE ERROR: approve failed - \$reason/,
    'an approve failure prints a classified STORE ERROR line, matching the established STDERR shape' );
like( $source, qr/STORE ERROR: is_allowed failed - \$reason/,
    'an is_allowed failure prints a classified STORE ERROR line, matching the established STDERR shape' );

# Both failure branches must exit non-zero (1), matching the script's
# own existing "nothing to approve"/"already allowed" exit(1) shape -
# a store-write/read failure is not a success.
my ($approve_block) = $source =~ /(my \$approved = eval.*?exit 1;\n\})/s;
ok( defined $approve_block, 'found the approve failure-handling block' );
like( $approve_block, qr/exit 1;/, 'an approve failure exits 1, not 0' );

done_testing();
