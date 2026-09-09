use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

local $ENV{D2TG_TOKEN}   = 'test-token';
local $ENV{D2TG_CHAT_ID} = '12345';

require D2TG::Config;

is( D2TG::Config::token(),   'test-token', 'token() reads D2TG_TOKEN' );
is( D2TG::Config::chat_id(), '12345',      'chat_id() reads D2TG_CHAT_ID' );

ok( D2TG::Config::require_chat_id_or_warn(),
    'require_chat_id_or_warn() succeeds when D2TG_CHAT_ID is set' );

{
    local $ENV{D2TG_CHAT_ID} = '';
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $ok = D2TG::Config::require_chat_id_or_warn();

    ok( !$ok, 'require_chat_id_or_warn() fails when D2TG_CHAT_ID is empty' );
    like(
        $warned,
        qr/D2TG_CHAT_ID/,
        'a warning naming D2TG_CHAT_ID is printed'
    );
}

{
    delete local $ENV{D2TG_CHAT_ID};
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $ok = D2TG::Config::require_chat_id_or_warn();

    ok( !$ok, 'require_chat_id_or_warn() fails when D2TG_CHAT_ID is truly unset (undef)' );
    like(
        $warned,
        qr/D2TG_CHAT_ID/,
        'a warning naming D2TG_CHAT_ID is printed for the undef case too'
    );
}

{
    # TGT-155 (JOB-003 scheduled hourly bug hunt finding, 2026-09-09):
    # chat_id() returns $ENV{D2TG_CHAT_ID} completely raw, with no
    # trimming - a whitespace-only value (a copy-paste error, a shell
    # quoting mistake, a templated .env file leaving a stray space)
    # previously passed this check (not undef, not eq '') and let the
    # poller start, silently seeding that literal whitespace string as
    # the admin's chat_id in D2TG::Store - Telegram's real numeric
    # chat_id can never match it, so the real owner was locked out
    # forever with zero warning.
    local $ENV{D2TG_CHAT_ID} = '   ';
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $ok = D2TG::Config::require_chat_id_or_warn();

    ok( !$ok, 'require_chat_id_or_warn() fails when D2TG_CHAT_ID is whitespace-only' );
    like(
        $warned,
        qr/D2TG_CHAT_ID/,
        'a warning naming D2TG_CHAT_ID is printed for the whitespace-only case too'
    );
}

{
    # A tab character counts as whitespace too, not just a literal space.
    local $ENV{D2TG_CHAT_ID} = "\t";
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $ok = D2TG::Config::require_chat_id_or_warn();

    ok( !$ok, 'require_chat_id_or_warn() fails when D2TG_CHAT_ID is a bare tab' );
    like( $warned, qr/D2TG_CHAT_ID/, 'a warning naming D2TG_CHAT_ID is printed for the tab case too' );
}

{
    # Codex review finding: the original whitespace-only fix (/^\s*$/)
    # missed the more important case - leading/trailing whitespace
    # AROUND an otherwise-valid numeric id (a copy-paste that grabbed a
    # stray space along with the real digits). Telegram's own chat_id
    # is still never string-eq matched by the mangled value, so this
    # must refuse too, not just the entirely-blank case.
    local $ENV{D2TG_CHAT_ID} = ' 12345 ';
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $ok = D2TG::Config::require_chat_id_or_warn();

    ok( !$ok, 'require_chat_id_or_warn() fails when D2TG_CHAT_ID has leading/trailing whitespace around a valid id' );
    like( $warned, qr/D2TG_CHAT_ID/, 'a warning naming D2TG_CHAT_ID is printed for the padded-id case too' );
}

{
    # A leading tab before an otherwise-valid id - same failure shape,
    # different whitespace character.
    local $ENV{D2TG_CHAT_ID} = "\t12345";
    my $ok = D2TG::Config::require_chat_id_or_warn();
    ok( !$ok, 'require_chat_id_or_warn() fails when D2TG_CHAT_ID has a leading tab before a valid id' );
}

{
    # A negative chat id (Telegram's own shape for a group/supergroup/
    # channel, per the Bot API) must still be accepted - the fix
    # validates canonical shape, not merely "digits only".
    local $ENV{D2TG_CHAT_ID} = '-100123456789';
    ok( D2TG::Config::require_chat_id_or_warn(),
        'require_chat_id_or_warn() succeeds for a negative (group/channel-shaped) chat id' );
}

done_testing();
