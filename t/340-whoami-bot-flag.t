use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-340 (found via a live, user-requested adversarial improvement
# hunt): unlike nearly every other d2 tg.* command (fetch/attachment/
# history/unread/approve/retry-download/retry-transcription), d2
# tg.whoami had no --bot <token> flag at all - it always reported
# D2TG_TOKEN's own masked value, with no way to confirm a different
# configured bot's token in a multi-bot install. Omitting --bot must
# keep today's exact single-bot output unchanged.

my $whoami_cli = File::Spec->catfile( $Bin, '..', 'cli', 'whoami.pl' );

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $other_token = '987654321:ZZOtherTokenZZZZZZZZZZZZZZZZZZZZZZZZZZZ';
    my $out = `$whoami_cli --bot '$other_token' 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'd2 tg.whoami --bot <token> exits 0' );
    like( $out, qr/9876\.\.\.ZZZZ/, 'reports the masked value of the --bot token, not D2TG_TOKEN' );
    unlike( $out, qr/1234\.\.\.AAAA/, 'does NOT report D2TG_TOKEN\'s own masked value when --bot is given' );
    unlike( $out, qr/\Q$other_token\E/, 'the raw --bot token never appears on stdout' );
}

{
    # Omitting --bot must be byte-for-byte unchanged from before this
    # ticket - the default single-bot behavior.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $out = `$whoami_cli`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'd2 tg.whoami with no --bot still exits 0' );
    like( $out, qr/1234\.\.\.AAAA/, 'still reports D2TG_TOKEN\'s own masked value when --bot is omitted' );
}

{
    # A bare trailing --bot with no value must refuse cleanly, matching
    # every sibling command's own --bot validation.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $out = `$whoami_cli --bot 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'a bare trailing --bot with no value refuses' );
    like( $out, qr/--bot requires a value/, 'the message names the actual problem' );
}

done_testing();
