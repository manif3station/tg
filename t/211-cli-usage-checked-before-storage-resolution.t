use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-211 (found via a scheduled JOB-004 improvement hunt): two families
# of cli/*.pl scripts perform the same 3 checks (extract --db, validate
# positional/usage args, resolve+require the storage dir) but in
# different orders. cli/whoami.pl, cli/text-only-replies.pl,
# cli/unread.pl, cli/status.pl validate argv shape FIRST (exit 2,
# Usage:) then resolve storage. cli/attachment.pl, cli/retry-download.pl,
# cli/approve.pl resolve storage FIRST (exit 1 on a missing storage dir)
# then validate argv shape - the minority family this ticket reorders.
#
# When BOTH the storage location is missing AND positional args are
# malformed, a caller gets an inconsistent signal (exit 1/storage-error
# vs. exit 2/Usage:) depending only on which sibling command they
# called. This test uses setup_mandatory_db_env's own fake
# Developer::Dashboard (t/lib/Developer/Dashboard.pm) to resolve --db
# testalias to a directory that is never actually created - making
# require_existing_base_dir fail exactly like a real missing storage
# location would, without needing a real Developer Dashboard install
# (this container has none - see t/42-db-flag-cli-integration.t's own
# skip-guard for the same limitation) - combined with malformed
# positional args, and asserts every affected script now behaves like
# the majority family: exit 2 with a Usage: message, never exit 1.

my %scripts = (
    'attachment.pl' => {
        cli  => File::Spec->catfile( $Bin, '..', 'cli', 'attachment.pl' ),
        args => [ 'not-a-number', 'also-not-a-number' ],
    },
    'retry-download.pl' => {
        cli  => File::Spec->catfile( $Bin, '..', 'cli', 'retry-download.pl' ),
        args => [ 'not-a-number', 'extra-leftover-arg' ],
    },
    'approve.pl' => {
        cli  => File::Spec->catfile( $Bin, '..', 'cli', 'approve.pl' ),
        args => ['not-a-number'],
    },
);

for my $name ( sort keys %scripts ) {
    my $cli  = $scripts{$name}{cli};
    my $args = join ' ', @{ $scripts{$name}{args} };

    local %ENV = %ENV;
    setup_mandatory_db_env( $Bin, File::Spec->catdir( tempdir( CLEANUP => 1 ), 'never-created' ) );

    my $out = `$cli $args 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 2, "cli/$name with a missing storage location AND malformed args exits 2 (Usage), not 1 (storage error)" )
      or diag "Output was: $out";
    like( $out, qr/^Usage:/m, "cli/${name}'s output is the Usage: message, not a storage-resolution error" );
    unlike( $out, qr/does not exist - refusing to start/, "cli/$name never reaches the storage-resolution error when args are also malformed" );
}

done_testing();
