package D2TG::Store::RetryQueue;

use strict;
use warnings;

# TGT-101: the single-bot/unscoped sentinel for failed_downloads/
# failed_transcriptions' bot_key column (TGT-098) - named once here
# rather than repeated as a bare '' literal at every call site, mirroring
# D2TG::Store's own constant of the same name (this module has no
# dependency on D2TG::Store itself, so the constant is duplicated here
# rather than imported).
use constant DEFAULT_BOT_KEY => '';

# TGT-221 (Q-015 answered by Michael: retry every 60s for up to 5
# minutes total, independent of poll cadence): rows still within the
# 5-minute auto-retry window (measured from created_at, when the
# failure was first queued) and not attempted in the last 60s
# (last_retry_at NULL - never attempted - or older than 60s). A row
# past the 5-minute window is deliberately excluded here, not deleted -
# it stays fully visible/retryable via failed_downloads/
# d2 tg.retry-download exactly as before, only automatic retry gives up.
use constant AUTO_RETRY_INTERVAL_SECONDS => 60;
use constant AUTO_RETRY_WINDOW_SECONDS   => 300;

sub new {
    my ( $class, %args ) = @_;

    my $dbh = $args{dbh} or die "D2TG::Store::RetryQueue->new requires dbh\n";

    return bless { dbh => $dbh }, $class;
}

# TGT-295 (found via a user-requested comprehensive bug/improvement
# sweep): the download and transcription sides of this module were
# byte-for-byte twins differing only by table name and a handful of
# extra columns (media_kind/caption_note/local_path exist only on the
# download side). These 5 private helpers are table-parameterized so
# each public pair below can delegate to one shared implementation -
# zero behavior change, only one copy of the logic. $table is always
# one of the two literal strings passed by this module's own public
# subs below, never external input.
sub _record_failed {
    my ( $self, $table, $chat_id, $message_id, $file_id, $extra_columns, $args ) = @_;

    my @extra_names = @$extra_columns;
    my @extra_vals  = @{$args}{@extra_names};
    my $bot_key     = $args->{bot_key} // DEFAULT_BOT_KEY;

    my $columns_sql      = join( ', ', 'chat_id', 'bot_key', 'message_id', 'file_id', @extra_names );
    my $placeholders_sql = join( ', ', ('?') x ( 4 + @extra_names ) );
    my $update_sql       = join( ', ', map {"$_ = excluded.$_"} 'file_id', @extra_names ) . ', created_at = CURRENT_TIMESTAMP';

    # ON CONFLICT (chat_id, bot_key, message_id) - TGT-219 added bot_key
    # to this key so the same message_id failing under two different
    # bots in a multi-bot config queues two independent rows, not one
    # collapsed into the other. Telegram's own at-least-once delivery
    # can still reprocess the same update under the SAME bot (e.g. the
    # poller crashes after this call but before its offset advances) -
    # that case still refreshes the existing row's file_id/error/
    # timestamp instead of inserting a second queue entry.
    $self->{dbh}->do(
        "INSERT INTO $table ($columns_sql)
         VALUES ($placeholders_sql)
         ON CONFLICT(chat_id, bot_key, message_id) DO UPDATE SET $update_sql",
        undef, $chat_id, $bot_key, $message_id, $file_id, @extra_vals,
    );

    # TGT-225 (found via a scheduled JOB-003 hourly bug hunt): this
    # id-lookup was never updated for TGT-219's own bot_key-scoped
    # UNIQUE constraint above - with two rows sharing (chat_id,
    # message_id) but different bot_key, an unscoped SELECT could
    # return either row's id at random (in practice, SQLite's own
    # insertion order), not necessarily the one just written here.
    my $row = $self->{dbh}->selectrow_hashref(
        "SELECT id FROM $table WHERE chat_id = ? AND bot_key = ? AND message_id = ?",
        undef, $chat_id, $bot_key, $message_id,
    );

    return $row->{id};
}

sub _list_failed {
    my ( $self, $table, $select_columns, %args ) = @_;

    # TGT-219: optional bot_key filter, matching pending_chat_ids' own
    # established pattern - the unscoped case keeps its existing shape
    # (now also naming each row's own bot_key, so a caller can tell
    # which bot queued it even without filtering).
    if ( defined $args{bot_key} ) {
        return $self->{dbh}->selectall_arrayref(
            "SELECT $select_columns FROM $table WHERE bot_key = ? ORDER BY id",
            { Slice => {} }, $args{bot_key},
        );
    }

    return $self->{dbh}->selectall_arrayref(
        "SELECT $select_columns FROM $table ORDER BY id",
        { Slice => {} }
    );
}

my $DOWNLOAD_COLUMNS      = 'id, chat_id, bot_key, message_id, file_id, sender, media_kind, caption_note, error, created_at, local_path, last_retry_at';
my $TRANSCRIPTION_COLUMNS = 'id, chat_id, bot_key, message_id, file_id, sender, error, created_at, last_retry_at';

sub record_failed_download {
    my ( $self, $chat_id, $message_id, $file_id, %args ) = @_;
    return $self->_record_failed( 'failed_downloads', $chat_id, $message_id, $file_id,
        [qw(sender media_kind caption_note error)], \%args );
}

sub failed_downloads {
    my ( $self, %args ) = @_;
    return $self->_list_failed( 'failed_downloads', $DOWNLOAD_COLUMNS, %args );
}

# TGT-270 (a live report from Michael via the budget project): a
# redelivered update whose media download already failed and was
# queued had no way to be recognized as such by D2TG::Poller::run_once
# - only D2TG::Store::get_message (the messages table) was checked
# before re-announcing/re-attempting, and a failed download never
# calls record_message. Used by run_once's own redelivery-dedup guard
# alongside get_message.
sub has_failed_download {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $row = $self->{dbh}->selectrow_arrayref(
        'SELECT 1 FROM failed_downloads WHERE chat_id = ? AND bot_key = ? AND message_id = ? LIMIT 1',
        undef, $chat_id, $bot_key, $message_id,
    );
    return $row ? 1 : 0;
}

sub _due_for_retry {
    my ( $self, $table, $select_columns, %args ) = @_;

    my $sql = "SELECT $select_columns
         FROM $table
         WHERE datetime(created_at) >= datetime('now', ?)
           AND (last_retry_at IS NULL OR datetime(last_retry_at) <= datetime('now', ?))";
    my @bind = ( '-' . AUTO_RETRY_WINDOW_SECONDS . ' seconds', '-' . AUTO_RETRY_INTERVAL_SECONDS . ' seconds' );

    if ( defined $args{bot_key} ) {
        $sql .= ' AND bot_key = ?';
        push @bind, $args{bot_key};
    }
    $sql .= ' ORDER BY id';

    return $self->{dbh}->selectall_arrayref( $sql, { Slice => {} }, @bind );
}

sub _mark_retried {
    my ( $self, $table, $id ) = @_;

    $self->{dbh}->do( "UPDATE $table SET last_retry_at = CURRENT_TIMESTAMP WHERE id = ?", undef, $id );

    return;
}

sub _remove_failed {
    my ( $self, $table, $id ) = @_;

    $self->{dbh}->do( "DELETE FROM $table WHERE id = ?", undef, $id );

    return;
}

sub failed_downloads_due_for_retry {
    my ( $self, %args ) = @_;
    return $self->_due_for_retry( 'failed_downloads', $DOWNLOAD_COLUMNS, %args );
}

sub mark_failed_download_retried {
    my ( $self, $id ) = @_;
    return $self->_mark_retried( 'failed_downloads', $id );
}

sub remove_failed_download {
    my ( $self, $id ) = @_;
    return $self->_remove_failed( 'failed_downloads', $id );
}

# TGT-196: persists a queued row's own successfully-downloaded local
# path once download_file has already succeeded, so a future retry
# (D2TG::Download::retry_failed_download) can see it via failed_downloads
# and skip download_file entirely - retrying only the record_message
# write that's actually still failing, instead of re-fetching the same
# file from Telegram on every pass.
sub mark_failed_download_downloaded {
    my ( $self, $id, $local_path ) = @_;

    $self->{dbh}->do( 'UPDATE failed_downloads SET local_path = ? WHERE id = ?', undef, $local_path, $id );

    return;
}

# TGT-237: mirrors record_failed_download/failed_downloads/
# remove_failed_download's own shape exactly (upsert on
# (chat_id, bot_key, message_id), optional bot_key filter on listing) -
# see that trio's own comments above for the redelivery-refresh and
# multi-bot-isolation rationale, unchanged here.
sub record_failed_transcription {
    my ( $self, $chat_id, $message_id, $file_id, %args ) = @_;
    return $self->_record_failed( 'failed_transcriptions', $chat_id, $message_id, $file_id,
        [qw(sender error)], \%args );
}

sub failed_transcriptions {
    my ( $self, %args ) = @_;
    return $self->_list_failed( 'failed_transcriptions', $TRANSCRIPTION_COLUMNS, %args );
}

# TGT-270: has_failed_download's own analogue for transcriptions - used
# by run_once's redelivery-dedup guard alongside get_message.
sub has_failed_transcription {
    my ( $self, $chat_id, $message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $row = $self->{dbh}->selectrow_arrayref(
        'SELECT 1 FROM failed_transcriptions WHERE chat_id = ? AND bot_key = ? AND message_id = ? LIMIT 1',
        undef, $chat_id, $bot_key, $message_id,
    );
    return $row ? 1 : 0;
}

sub remove_failed_transcription {
    my ( $self, $id ) = @_;
    return $self->_remove_failed( 'failed_transcriptions', $id );
}

# TGT-246 (found via a scheduled JOB-003 hourly bug hunt): mirrors
# failed_downloads_due_for_retry/mark_failed_download_retried exactly
# (TGT-221) - same AUTO_RETRY_INTERVAL_SECONDS/AUTO_RETRY_WINDOW_SECONDS
# constants, same created_at/last_retry_at windowing logic, both now
# delegating to the shared _due_for_retry/_mark_retried helpers
# (TGT-295).
sub failed_transcriptions_due_for_retry {
    my ( $self, %args ) = @_;
    return $self->_due_for_retry( 'failed_transcriptions', $TRANSCRIPTION_COLUMNS, %args );
}

sub mark_failed_transcription_retried {
    my ( $self, $id ) = @_;
    return $self->_mark_retried( 'failed_transcriptions', $id );
}

1;

__END__

=head1 NAME

D2TG::Store::RetryQueue - failed-download/failed-transcription retry queue storage

=head1 SYNOPSIS

    my $rq = D2TG::Store::RetryQueue->new( dbh => $dbh );
    my $id = $rq->record_failed_download( $chat_id, $message_id, $file_id, %opts );

=head1 DESCRIPTION

TGT-257: extracted out of D2TG::Store.pm (which had grown to 1528 lines)
so its two retry-queue tables (C<failed_downloads>, C<failed_transcriptions>)
and their ten subs live in their own focused module. D2TG::Store keeps
thin forwarding methods with the same names for every existing caller
(cli/retry-download.pl, cli/unread.pl, cli/poller.pl, D2TG::Download,
D2TG::Transcribe and their tests) - this module has no behavior change
from what D2TG::Store used to do inline, only a new home.

This module does not create its own DBI handle or manage schema - it
takes an already-connected C<$dbh> (with the C<failed_downloads>/
C<failed_transcriptions> tables already present, per D2TG::Store's own
C<_ensure_schema>) and operates on it directly, the same as
D2TG::Store's other methods do via C<$self-E<gt>{dbh}>.

=head1 METHODS

=head2 new(dbh => $dbh)

Wraps an existing DBI handle. Dies if C<dbh> is not given.

=head2 record_failed_download($chat_id, $message_id, $file_id, %opts)

Queues (or refreshes, on redelivery of the same message) a failed
download. C<%opts>: C<sender>, C<media_kind>, C<caption_note>, C<error>,
C<bot_key> (defaults to the unscoped sentinel). Returns the row's id.

=head2 failed_downloads(%opts)

Lists all queued failed downloads, optionally filtered by C<bot_key>.

=head2 failed_downloads_due_for_retry(%opts)

Lists failed downloads still within the automatic-retry window
(L</AUTO_RETRY_WINDOW_SECONDS> since queued) and not retried in the last
L</AUTO_RETRY_INTERVAL_SECONDS>, optionally filtered by C<bot_key>.

=head2 mark_failed_download_retried($id)

Stamps a row's C<last_retry_at> to now.

=head2 remove_failed_download($id)

Deletes a row from the queue.

=head2 mark_failed_download_downloaded($id, $local_path)

Persists a queued row's own successfully-downloaded local path (TGT-196),
so a future retry can skip re-downloading and retry only the failing
C<record_message> write.

=head2 record_failed_transcription($chat_id, $message_id, $file_id, %opts)

Mirrors L</record_failed_download> exactly, for the C<failed_transcriptions>
table. C<%opts>: C<sender>, C<error>, C<bot_key>.

=head2 failed_transcriptions(%opts)

Mirrors L</failed_downloads>.

=head2 failed_transcriptions_due_for_retry(%opts)

Mirrors L</failed_downloads_due_for_retry>.

=head2 mark_failed_transcription_retried($id)

Mirrors L</mark_failed_download_retried>.

=head2 remove_failed_transcription($id)

Mirrors L</remove_failed_download>.

=head1 IMPLEMENTATION NOTES

TGT-295 (found via a user-requested comprehensive bug/improvement
sweep): every method pair described above as "mirrors X exactly" now
literally shares one implementation - 5 private, table-parameterized
helpers (C<_record_failed>, C<_list_failed>, C<_due_for_retry>,
C<_mark_retried>, C<_remove_failed>) that each public method above
delegates to, rather than two independently-maintained copies of the
same SQL differing only by table name. Zero behavior change; every
public method's own signature, defaults, and return shape are
unchanged.

=cut
