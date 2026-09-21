package D2TG::Store::History;

use strict;
use warnings;

# TGT-101: the single-bot/unscoped sentinel for messages' bot_key
# column (TGT-098) - named once here rather than repeated as a bare ''
# literal at every call site, mirroring D2TG::Store's own constant of
# the same name (this module has no dependency on D2TG::Store itself,
# matching D2TG::Store::RetryQueue's own precedent).
use constant DEFAULT_BOT_KEY => '';

sub new {
    my ( $class, %args ) = @_;

    my $dbh = $args{dbh} or die "D2TG::Store::History->new requires dbh\n";

    return bless { dbh => $dbh }, $class;
}

# TGT-324 (found via a live JOB-004 improvement hunt): unread_messages,
# recent_messages, and messages_in_range each independently build their
# own $sql/@bind, but all three ended with the exact same 2 lines -
# running selectall_arrayref and returning the dereferenced list.
# Collapsed here; each call site now passes its own $sql/@bind and
# gets back the same list it always did.
sub _select_all_rows {
    my ( $self, $sql, @bind ) = @_;
    my $rows = $self->{dbh}->selectall_arrayref( $sql, { Slice => {} }, @bind );
    return @$rows;
}

sub record_message {
    my ( $self, $chat_id, $message_id, $sender, $summary, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    $self->{dbh}->do(
        'INSERT INTO messages (chat_id, bot_key, message_id, sender, summary, local_path) VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(chat_id, bot_key, message_id) DO UPDATE SET sender = excluded.sender, summary = excluded.summary, local_path = COALESCE(excluded.local_path, messages.local_path)',
        undef, $chat_id, $bot_key, $message_id, $sender, $summary, $args{local_path},
    );

    return;
}

sub get_message {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT sender, summary FROM messages WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return $row;
}

sub get_attachment_path {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT local_path FROM messages WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return $row ? $row->{local_path} : undef;
}

sub mark_read {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    $self->{dbh}->do(
        'UPDATE messages SET read_at = CURRENT_TIMESTAMP WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return;
}

sub is_read {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my ($read_at) = $self->{dbh}->selectrow_array(
        'SELECT read_at FROM messages WHERE chat_id = ? AND bot_key = ? AND message_id = ?',
        undef, $chat_id, $bot_key, $message_id,
    );

    return defined $read_at ? 1 : 0;
}

sub unread_messages {
    my ( $self, %args ) = @_;

    my $sql  = 'SELECT chat_id, message_id, sender, summary, created_at FROM messages WHERE read_at IS NULL';
    my @bind;
    if ( defined $args{bot_key} ) {
        $sql .= ' AND bot_key = ?';
        push @bind, $args{bot_key};
    }
    $sql .= ' ORDER BY created_at, message_id';

    return $self->_select_all_rows( $sql, @bind );
}

sub recent_messages {
    my ( $self, $limit, %args ) = @_;
    $limit //= 10;

    my $sql = 'SELECT chat_id, message_id, sender, summary, created_at FROM messages';
    my @bind;
    if ( defined $args{bot_key} ) {
        $sql .= ' WHERE bot_key = ?';
        push @bind, $args{bot_key};
    }
    $sql .= ' ORDER BY created_at DESC, message_id DESC LIMIT ?';
    push @bind, $limit;

    return $self->_select_all_rows( $sql, @bind );
}

sub messages_in_range {
    my ( $self, %args ) = @_;

    my @where;
    my @bind;

    if ( defined $args{bot_key} ) {
        push @where, 'bot_key = ?';
        push @bind,  $args{bot_key};
    }

    # TGT-214 (found via a scheduled JOB-003 hourly bug hunt, live-
    # verified): a plain string comparison against the raw --since/
    # --until value used to silently exclude same-day messages -
    # created_at is stored SQLite-CURRENT_TIMESTAMP-style, space-
    # separated ('2026-09-01 08:00:00'), but cli/history.pl's own
    # documented/TGT-209-validated form uses a 'T' separator
    # ('2026-09-01T00:00:00'); since 'T' (0x54) sorts after a space
    # (0x20), a since value with a time component compared greater
    # than every same-day row regardless of actual time-of-day.
    # SQLite's own datetime() normalizes any of its several accepted
    # input formats (date-only, space-separated, T-separated) to one
    # canonical form before comparing, so wrapping both sides in it
    # compares by real chronological value instead of raw string
    # ordering - deliberately applied to both the column and the bound
    # value, not just one side, so a canonical date-only value (which
    # datetime() expands to midnight) still compares correctly against
    # a full timestamp on either side of the comparison.
    if ( defined $args{since} ) {
        push @where, 'datetime(created_at) >= datetime(?)';
        push @bind,  $args{since};
    }
    if ( defined $args{until} ) {
        push @where, 'datetime(created_at) <= datetime(?)';
        push @bind,  $args{until};
    }

    my $sql = 'SELECT chat_id, message_id, sender, summary, created_at FROM messages';
    $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;
    $sql .= ' ORDER BY created_at, message_id';

    return $self->_select_all_rows( $sql, @bind );
}

1;
