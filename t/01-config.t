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

done_testing();
