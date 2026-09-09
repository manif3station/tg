use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);

my $unread_cli = File::Spec->catfile( $Bin, '..', 'cli', 'unread.pl' );

use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );
$ENV{D2TG_CHAT_ID} = '999999';

# TGT-149 (found via a scheduled hourly bug-hunt): cli/unread.pl
# extracted --db/-d but never checked that nothing unrecognized
# remained afterward, unlike cli/status.pl, cli/history.pl (TGT-122),
# cli/whoami.pl, and cli/text-only-replies.pl - all 4 sibling commands
# in the same family already refuse. Live reproduced before this fix:
# both cases below printed "No unread messages." and exited 0 instead
# of refusing.

{
    my $out = `$unread_cli --totally-bogus-flag 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 2, 'cli/unread with an unrecognized flag refuses with exit 2' );
    like( $out, qr/Usage/i, 'the message names it as a usage problem' );
    unlike( $out, qr/^No unread messages\.$/m, 'never silently claims a clean result for an unrecognized flag' );
}

{
    my $out = `$unread_cli some garbage positional args 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 2, 'cli/unread with leftover positional arguments refuses with exit 2' );
    like( $out, qr/Usage/i, 'the message names it as a usage problem' );
    unlike( $out, qr/^No unread messages\.$/m, 'never silently claims a clean result for leftover args' );
}

# Every existing valid-usage case must be completely unaffected.
{
    my $out = `$unread_cli 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'no arguments at all still exits 0' );
    like( $out, qr/No unread messages\./, 'and still reports the expected clean message' );
}

{
    my $out = `$unread_cli --db testalias 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, '--db <alias> alone still exits 0' );
    like( $out, qr/No unread messages\./, 'and still reports the expected clean message' );
}

{
    my $out = `$unread_cli -d testalias 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, '-d <alias> still exits 0' );
    like( $out, qr/No unread messages\./, 'and still reports the expected clean message' );
}

done_testing();
