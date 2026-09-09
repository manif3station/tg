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

sub _run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-86-stderr.$$";
    my $out = `@cmd 2>$err_file`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;
    return ( $out, $rc, $err );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my ( $out, $rc, $err ) = _run_capturing_stderr($whoami_cli);

    is( $rc, 0, 'd2 tg.whoami exits 0' );
    like( $out, qr/1234\.\.\.AAAA/, 'prints the masked token, not the raw one' );
    unlike( $out, qr/123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA/, 'the raw token never appears on stdout' );
    unlike( $err, qr/123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA/, 'the raw token never appears on stderr either (Codex review finding)' );
    like( $out, qr/398296603/, 'prints the configured chat_id' );
    like( $out, qr/\.tira/, 'prints the resolved storage location' );
    like( $out, qr/^attachments: /m, 'prints the resolved attachments location too' );
}

# Codex review finding: masked_token's own existing short-token
# behavior (< 8 chars printed unmasked) is D2TG::Config's established
# design, already relied on by cli/status.pl and cli/poller.pl's own
# startup line - out of scope for this ticket to change (scope_out:
# "Any change to how the token/chat_id/storage location are themselves
# resolved"). Confirmed here as existing, not a new regression this
# ticket introduces.
{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'short';
    $ENV{D2TG_CHAT_ID} = '1';

    my $out = `$whoami_cli`;
    like( $out, qr/token: short/, 'a short (<8 char) token is shown as-is - existing D2TG::Config::masked_token behavior, not something this ticket changes' );
}

# Codex review finding: --db/-d must actually change the reported
# storage location, not just be silently accepted.
{
    my $fake_db_dir_a = tempdir( CLEANUP => 1 );
    my $fake_db_dir_b = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir_a );
    local %ENV = %ENV;
    $ENV{D2TG_TEST_DB_DIR}   = $fake_db_dir_b;
    $ENV{D2TG_TEST_DB_ALIAS} = 'testalias2';
    delete $ENV{D2TG_DB};

    my $out = `$whoami_cli --db testalias2`;
    like( $out, qr/\Q$fake_db_dir_b\E/, '--db resolves to the requested alias\'s own directory, not the D2TG_DB default' );
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
    # d2 tg.whoami must never make a network call. A source-level check
    # can't prove behavior, but it's a real, cheap tripwire: catches the
    # obvious regressions (loading D2TG::Telegram, or any of the raw
    # HTTP-client modules this project's other code actually uses) so a
    # later change reintroducing a network call here doesn't slip past
    # silently (a Codex review finding: the original version of this
    # test only checked for D2TG::Telegram specifically).
    open my $fh, '<', $whoami_cli or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;

    for my $network_module (qw(D2TG::Telegram LWP::UserAgent HTTP::Tiny HTTP::Request Net::HTTP)) {
        unlike( $source, qr/^\s*use\s+\Q$network_module\E/m, "cli/whoami.pl never \"use\"s $network_module" );
    }
    unlike( $source, qr/\bsystem\s*\(|`[^`]*curl|`[^`]*wget/, 'cli/whoami.pl never shells out to curl/wget or system()' );
}

done_testing();
