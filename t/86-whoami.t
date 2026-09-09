use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-115 (user-supplied feature-gap analysis, /tmp/missing2.md item 6):
# no cheap way existed to confirm which project's bot/log a poller
# instance is actually configured for, without either reading raw env
# vars by hand or risking a real network call. d2 tg.whoami is a
# read-only identity/sanity check - masked token, chat_id, and the
# resolved storage location - with no HTTP request made at all.

my $whoami_cli = File::Spec->catfile( $Bin, '..', 'cli', 'whoami.pl' );

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $out = `$whoami_cli`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'd2 tg.whoami exits 0' );
    like( $out, qr/1234\.\.\.AAAA/, 'prints the masked token, not the raw one' );
    unlike( $out, qr/123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA/, 'the raw token never appears in the output' );
    like( $out, qr/398296603/, 'prints the configured chat_id' );
    like( $out, qr/\.tira/, 'prints the resolved storage location' );
}

{
    # Neither env var set - must still work, reporting "(not set)"
    # rather than dying, since this is meant to be a safe sanity check
    # to run BEFORE confirming config is correct.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    my $out = `$whoami_cli`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'd2 tg.whoami still exits 0 with no token/chat_id configured' );
    like( $out, qr/\(not set\)/, 'reports "(not set)" for the missing token' );
    like( $out, qr/chat_id: \(not set\)/, 'reports "(not set)" for the missing chat_id' );
}

{
    my ( $out, $rc ) = ( `$whoami_cli --bogus 2>&1`, $? >> 8 );
    isnt( $rc, 0, 'an unrecognized argument refuses' );
    like( $out, qr/Usage/, 'usage refusal names the correct usage' );
}

{
    # d2 tg.whoami must never make a network call - confirmed by the
    # absence of any D2TG::Telegram usage in the script's own source.
    open my $fh, '<', $whoami_cli or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;

    unlike( $source, qr/^\s*use\s+D2TG::Telegram/m, 'cli/whoami.pl never "use"s D2TG::Telegram - no network call is even possible' );
}

done_testing();
