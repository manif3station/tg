use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);

my $history_cli = File::Spec->catfile( $Bin, '..', 'cli', 'history' );

# TGT-059: --db/-d/D2TG_DB is now mandatory, so every subprocess spawned
# below needs it resolvable without a real Developer Dashboard install -
# see t/lib/Developer/Dashboard.pm.
$ENV{PERL5LIB} = join( ':', File::Spec->catdir( $Bin, 'lib' ), $ENV{PERL5LIB} // '' );
$ENV{D2TG_DB}            = 'testalias';
$ENV{D2TG_TEST_DB_ALIAS} = 'testalias';
$ENV{D2TG_TEST_DB_DIR}   = tempdir( CLEANUP => 1 );
$ENV{D2TG_CHAT_ID}       = '999999';

# TGT-070: a bare trailing --since (no value) previously silently ran
# the query unscoped instead of erroring on the malformed invocation -
# live-verified before this fix ("No messages found." + exit 0).
{
    my $out = `$history_cli --since 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since (bare, no value) refuses instead of silently running unscoped' );
    like( $out, qr/--since.*requires a value|Usage/i, 'the message names the actual problem' );
    unlike( $out, qr/^No messages found\.$/m, 'never silently claims a scoped-but-empty result for a malformed invocation' );
}

# --since immediately followed by --until previously swallowed
# '--until' itself as the since value, silently mis-scoping the query.
{
    my $out = `$history_cli --since --until 2026-01-01 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since --until <date> refuses instead of swallowing --until as the since value' );
    like( $out, qr/--since.*requires a value|Usage/i, 'the message names the actual problem' );
}

# A normal --since/--until pair must be completely unaffected.
{
    my $out = `$history_cli --since 2026-01-01T00:00:00 --until 2026-02-01T00:00:00 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a normal --since <date> --until <date> pair still exits 0' );
    like( $out, qr/No messages found\./, 'a normal range with no matching messages still reports the expected clean message' );
}

done_testing();
