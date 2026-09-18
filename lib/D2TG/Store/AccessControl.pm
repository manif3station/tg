package D2TG::Store::AccessControl;

use strict;
use warnings;

# TGT-101: the single-bot/unscoped sentinel for allow_list/pending's
# bot_key column (TGT-098) - named once here rather than repeated as a
# bare '' literal at every call site, mirroring D2TG::Store's own
# constant of the same name (this module has no dependency on
# D2TG::Store itself, matching D2TG::Store::RetryQueue/History's own
# precedent).
use constant DEFAULT_BOT_KEY => '';

sub new {
    my ( $class, %args ) = @_;

    my $dbh = $args{dbh} or die "D2TG::Store::AccessControl->new requires dbh\n";

    return bless { dbh => $dbh }, $class;
}

# TGT-297 (found via a user-requested comprehensive bug/improvement
# sweep): these 4 functions used positional-argument bot_key scoping
# while every sibling Store submodule extracted in the same TGT-278/279
# pass (History, SentReplyAudit, RetryQueue) uses %args-style. Now
# matches that convention - D2TG::Store.pm's own public forwarding
# methods (called by every existing test/cli caller) are unaffected;
# only this module's own signature and Store.pm's own direct calls into
# it changed.
sub seed_admin {
    my ( $self, $admin_chat_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    $self->{dbh}->do(
        'INSERT OR IGNORE INTO allow_list (chat_id, bot_key) VALUES (?, ?)',
        undef, $admin_chat_id, $bot_key,
    );

    return;
}

sub is_allowed {
    my ( $self, $chat_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my ($found) = $self->{dbh}->selectrow_array(
        'SELECT 1 FROM allow_list WHERE chat_id = ? AND bot_key = ?', undef, $chat_id, $bot_key,
    );

    return $found ? 1 : 0;
}

sub add_pending {
    my ( $self, $chat_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $inserted = $self->{dbh}->do(
        'INSERT OR IGNORE INTO pending (chat_id, bot_key) VALUES (?, ?)',
        undef, $chat_id, $bot_key,
    );

    return $inserted && $inserted ne '0E0' ? 1 : 0;
}

sub approve {
    my ( $self, $chat_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $dbh = $self->{dbh};

    $dbh->begin_work;

    my $result = eval {
        my $deleted = $dbh->do(
            'DELETE FROM pending WHERE chat_id = ? AND bot_key = ?', undef, $chat_id, $bot_key,
        );

        if ( $deleted == 0 ) {
            $dbh->rollback;
            return 0;
        }

        $dbh->do(
            'INSERT OR IGNORE INTO allow_list (chat_id, bot_key) VALUES (?, ?)',
            undef, $chat_id, $bot_key,
        );
        $dbh->commit;
        return 1;
    };
    my $error = $@;

    if ($error) {
        eval { $dbh->rollback };
        die $error;
    }

    return $result;
}

sub pending_chat_ids {
    my ( $self, %args ) = @_;

    # TGT-215 (found via a scheduled JOB-004 improvement hunt): the sole
    # pending/allow_list accessor never updated for TGT-098's bot_key
    # migration - added an optional bot_key filter matching every
    # sibling accessor's own established pattern. The unscoped case
    # deliberately keeps its existing flat chat_id-list return shape
    # (t/05-access-control.t/t/06-approve.t/t/111-reaction-access-
    # control.t all depend on it) - only adding DISTINCT so a chat_id
    # pending under multiple bots is never listed more than once.
    if ( defined $args{bot_key} ) {
        my $rows = $self->{dbh}->selectcol_arrayref(
            'SELECT chat_id FROM pending WHERE bot_key = ? ORDER BY chat_id',
            undef, $args{bot_key},
        );
        return @$rows;
    }

    my $rows = $self->{dbh}->selectcol_arrayref(
        'SELECT DISTINCT chat_id FROM pending ORDER BY chat_id'
    );

    return @$rows;
}

1;
