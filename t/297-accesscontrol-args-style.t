use strict;
use warnings;
use Test::More;
use DBI;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use D2TG::Store::AccessControl;

# TGT-297 (found via a user-requested comprehensive bug/improvement
# sweep): D2TG::Store::AccessControl.pm used positional-argument
# bot_key scoping (my ($self, $chat_id, $bot_key) = @_) in
# is_allowed/add_pending/approve/seed_admin, while every sibling Store
# submodule extracted in the same TGT-278/279 pass (History,
# SentReplyAudit, RetryQueue) uses %args-style
# (my (..., %args) = @_; my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY).
# D2TG::Store's own PUBLIC forwarding methods (is_allowed/add_pending/
# approve/seed_admin, called by every existing test and cli script) are
# NOT part of this ticket's scope - only AccessControl.pm's own
# internal convention, plus Store.pm's own direct calls into it, change.
# Zero observable behavior change to any external caller.

# Structural: AccessControl.pm's 4 functions now take %args, not a
# positional $bot_key.
{
    open my $fh, '<', $INC{'D2TG/Store/AccessControl.pm'} or die $!;
    local $/;
    my $source = <$fh>;
    close $fh;

    for my $fn (qw(is_allowed add_pending approve)) {
        like( $source, qr/sub \Q$fn\E \{\s*\n\s*my \( \$self, \$chat_id, %args \) = \@_;/,
            "$fn takes \%args, matching sibling modules" );
    }
    like( $source, qr/sub seed_admin \{\s*\n\s*my \( \$self, \$admin_chat_id, %args \) = \@_;/,
        'seed_admin takes %args, matching sibling modules' );

    unlike( $source, qr/my \( \$self, \$chat_id, \$bot_key \)/,
        'no function still takes a bare positional $bot_key' );
}

# Behavioral: zero observable behavior change via the new %args-style
# call directly on AccessControl.
my $dbh = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 } );
$dbh->do('CREATE TABLE allow_list (chat_id INTEGER, bot_key TEXT DEFAULT "", UNIQUE(chat_id, bot_key))');
$dbh->do('CREATE TABLE pending (chat_id INTEGER, bot_key TEXT DEFAULT "", UNIQUE(chat_id, bot_key))');

my $access = D2TG::Store::AccessControl->new( dbh => $dbh );

$access->seed_admin(999);
ok( $access->is_allowed(999), 'seed_admin/is_allowed with no bot_key still works (default sentinel)' );
ok( !$access->is_allowed( 999, bot_key => 'tokenA' ), 'is_allowed is bot_key-scoped when given' );

$access->seed_admin( 1111, bot_key => 'tokenA' );
ok( $access->is_allowed( 1111, bot_key => 'tokenA' ), 'seed_admin/is_allowed with bot_key => works' );
ok( !$access->is_allowed( 1111, bot_key => 'tokenB' ), 'a different bot_key is not allowed' );

ok( $access->add_pending( 2222, bot_key => 'tokenA' ), 'add_pending with bot_key => works' );
ok( $access->approve( 2222, bot_key => 'tokenA' ), 'approve with bot_key => works' );
ok( $access->is_allowed( 2222, bot_key => 'tokenA' ), 'approved chat id is allowed under its own bot_key' );

done_testing();
