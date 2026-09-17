package D2TG::Store::SentReplyAudit;

use strict;
use warnings;

# TGT-101: the single-bot/unscoped sentinel for sent_replies' bot_key
# column (TGT-098) - named once here rather than repeated as a bare ''
# literal at every call site, mirroring D2TG::Store's own constant of
# the same name (this module has no dependency on D2TG::Store itself,
# matching D2TG::Store::RetryQueue/History/AccessControl's own
# precedent).
use constant DEFAULT_BOT_KEY => '';

sub new {
    my ( $class, %args ) = @_;

    my $dbh = $args{dbh} or die "D2TG::Store::SentReplyAudit->new requires dbh\n";

    return bless { dbh => $dbh }, $class;
}

sub record_sent_text {
    my ( $self, $chat_id, $text_message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    # INSERT OR IGNORE: a redundant re-record of the same (chat_id,
    # bot_key, text_message_id) - e.g. a retried send_reply call after a
    # prior partial failure - must never clobber a voice_message_id
    # already recorded for it back to NULL.
    $self->{dbh}->do(
        'INSERT OR IGNORE INTO sent_replies (chat_id, bot_key, text_message_id, text) VALUES (?, ?, ?, ?)',
        undef, $chat_id, $bot_key, $text_message_id, $args{text},
    );

    return;
}

sub record_sent_voice {
    my ( $self, $chat_id, $text_message_id, $voice_message_id, %args ) = @_;
    my $bot_key = $args{bot_key} // DEFAULT_BOT_KEY;

    my $rows = $self->{dbh}->do(
        'UPDATE sent_replies SET voice_message_id = ? WHERE chat_id = ? AND bot_key = ? AND text_message_id = ?',
        undef, $voice_message_id, $chat_id, $bot_key, $text_message_id,
    );

    # Codex review finding: a matching text row not existing (a
    # bot_key mismatch, or the text row itself never got recorded -
    # e.g. a crash between send_message succeeding and record_sent_text
    # running) used to be a silent no-op, hiding exactly the kind of
    # persistence gap this feature exists to surface. Not fatal - the
    # voice send itself already succeeded and must not be undone or
    # treated as a failure - but worth a loud note rather than silence.
    warn "D2TG::Store::SentReplyAudit::record_sent_voice: no matching sent_replies row for "
      . "chat_id=$chat_id bot_key='$bot_key' text_message_id=$text_message_id "
      . "- voice sent but the text-only audit trail could not be updated\n"
      if !$rows || $rows eq '0E0';

    return;
}

sub text_only_replies {
    my ( $self, %args ) = @_;

    # bot_key (Codex review finding): optional filter, so a caller that
    # needs to act on exactly one bot's own flags (cli/reply.pl
    # --voice-only, so it never selects and clears a DIFFERENT bot's
    # flag for the same chat_id) can scope the query; omitting it lists
    # every bot's flagged replies, each row naming its own bot_key, for
    # a human operator auditing the whole board.
    if ( defined $args{bot_key} ) {
        return $self->{dbh}->selectall_arrayref(
            'SELECT chat_id, bot_key, text_message_id, created_at FROM sent_replies
             WHERE voice_message_id IS NULL AND bot_key = ? ORDER BY chat_id, text_message_id',
            { Slice => {} }, $args{bot_key},
        );
    }

    return $self->{dbh}->selectall_arrayref(
        'SELECT chat_id, bot_key, text_message_id, created_at FROM sent_replies
         WHERE voice_message_id IS NULL ORDER BY chat_id, bot_key, text_message_id',
        { Slice => {} }
    );
}

sub is_recent_duplicate_reply {
    my ( $self, $chat_id, $text, %args ) = @_;
    my $bot_key        = $args{bot_key}        // DEFAULT_BOT_KEY;
    my $window_seconds = $args{window_seconds} // 10;

    # Codex review finding: a negative window_seconds silently builds a
    # nonsensical SQLite modifier ("--10 seconds") that would otherwise
    # make the comparison behave unpredictably rather than obviously
    # wrong. A non-numeric value is rejected the same way.
    die "D2TG::Store::SentReplyAudit::is_recent_duplicate_reply: window_seconds must be a non-negative number\n"
      unless $window_seconds =~ /^\d+(?:\.\d+)?$/;

    my $row = $self->{dbh}->selectrow_hashref(
        "SELECT 1 FROM sent_replies
         WHERE chat_id = ? AND bot_key = ? AND text = ?
           AND created_at >= datetime('now', ?)
         LIMIT 1",
        undef, $chat_id, $bot_key, $text, "-$window_seconds seconds",
    );

    return $row ? 1 : 0;
}

1;
