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

unlike( $source, qr/if\s*\(\s*\$store->approve\(/,
    'approve is never called directly inside a conditional - only via the eval-captured $approved variable' );
unlike( $source, qr/if\s*\(\s*\$store->is_allowed\(/,
    'is_allowed is never called directly inside a conditional - only via the eval-captured $allowed variable' );

# A Codex QA-stage review finding: a global count of
# D2TG::Poller::_classify_store_error occurrences (even ">= 2") does
# not tie either failure branch to its own classifier call, and is
# thrown off by the POD's own prose mention of the same identifier -
# it would miss the more relevant partial regression of one branch
# staying eval-wrapped while reporting the raw $@ instead of the
# classified reason. Extract each individual failure-handling block
# (approve's own "if ($@) { ... }", and is_allowed's own) and assert
# each one, specifically, contains its own classifier call and its own
# STORE ERROR line - not a codebase-wide count.
my ($approve_error_block) = $source =~ /(my \$approved = eval.*?\n\}\n)/s;
ok( defined $approve_error_block, 'found the approve failure-handling block' );
like( $approve_error_block, qr/D2TG::Poller::_classify_store_error/,
    'the approve failure-handling block itself calls the classifier - not just somewhere else in the file' );
like( $approve_error_block, qr/STORE ERROR: approve failed - \$reason/,
    'the approve failure-handling block itself prints the classified STORE ERROR line' );
like( $approve_error_block, qr/exit 1;/, 'an approve failure exits 1, not 0' );

my ($is_allowed_error_block) = $source =~ /(my \$allowed = eval.*?\n\}\n)/s;
ok( defined $is_allowed_error_block, 'found the is_allowed failure-handling block' );
like( $is_allowed_error_block, qr/D2TG::Poller::_classify_store_error/,
    'the is_allowed failure-handling block itself calls the classifier - not just somewhere else in the file' );
like( $is_allowed_error_block, qr/STORE ERROR: is_allowed failed - \$reason/,
    'the is_allowed failure-handling block itself prints the classified STORE ERROR line' );
like( $is_allowed_error_block, qr/exit 1;/, 'an is_allowed failure exits 1, not 0' );

done_testing();
