package D2TG::Store;

use strict;
use warnings;
use DBI;
use Digest::SHA qw(sha256_hex);
use D2TG::Store::RetryQueue;
use D2TG::Store::History;
use D2TG::Store::AccessControl;
use D2TG::Store::SentReplyAudit;
use D2TG::Store::Schema;

# TGT-101: the single-bot/unscoped sentinel for allow_list/pending's
# bot_key column (TGT-098) - named once here rather than repeated as a
# bare '' literal at every call site.
use constant DEFAULT_BOT_KEY => '';

# TGT-235: the default age cap for prune_history, mirroring
# D2TG::Download::prune_vault's own named-constant-default pattern.
use constant DEFAULT_RETENTION_DAYS => 90;

# TGT-238: a separate, shorter default for failed_downloads/
# failed_transcriptions - these are retry queues, not history, so a
# permanently-unretryable row (an expired file_id, say) should stop
# cluttering d2 tg.unread's own listing well before a legitimate
# message would age out of history.
use constant DEFAULT_FAILED_QUEUE_RETENTION_DAYS => 30;

sub new {
    my ( $class, %args ) = @_;

    my $db_path = $args{db_path} or die "D2TG::Store->new requires db_path\n";

    # TGT-316 (found via a scheduled JOB-003 hourly bug hunt, reproduced
    # live): RaiseError and PrintError are independent DBI attributes -
    # RaiseError alone does not suppress PrintError's own STDERR warning
    # before the exception is raised, and DBI's own documented default
    # for PrintError is 1 (true). Without this, any DBI error not
    # already inside one of D2TG::Store::Schema's own local
    # "PrintError = 0" blocks leaks a raw, unclassified exception line
    # to STDERR - exactly the class of leak TGT-133/183/186/195/293/311
    # all exist to prevent, all of which assumed RaiseError alone was
    # sufficient.
    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_path", '', '',
        { RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_use_immediate_transaction => 1 }
    );

    # TGT-129: without these, DBD::SQLite's default busy timeout is 0 -
    # a concurrent writer (the long-running poller vs. an independently
    # invoked d2 tg.reply/approve/retry-download etc. against the same
    # db_path) gets an immediate "database is locked" error instead of
    # a brief, usually-successful wait. WAL also lets readers and a
    # writer proceed without blocking each other at all in the common
    # case; busy_timeout covers the remaining writer-vs-writer window.
    $dbh->do('PRAGMA busy_timeout = 5000');
    $dbh->do('PRAGMA journal_mode = WAL');

    my $self = bless { dbh => $dbh }, $class;
    D2TG::Store::Schema::ensure_schema($dbh);

    # TGT-257: failed_downloads/failed_transcriptions storage now lives
    # in D2TG::Store::RetryQueue - built once here and reused by every
    # forwarding method below, same $dbh, no behavior change for any
    # existing caller.
    $self->{retry_queue} = D2TG::Store::RetryQueue->new( dbh => $dbh );

    # TGT-278: message-history storage now lives in D2TG::Store::History
    # - built once here and reused by every forwarding method below,
    # same $dbh, no behavior change for any existing caller, mirroring
    # TGT-257's own retry_queue precedent above.
    $self->{history} = D2TG::Store::History->new( dbh => $dbh );

    # TGT-279: access-control storage now lives in
    # D2TG::Store::AccessControl - built once here and reused by every
    # forwarding method below, same $dbh, no behavior change for any
    # existing caller, mirroring TGT-257/278's own precedent above.
    $self->{access} = D2TG::Store::AccessControl->new( dbh => $dbh );

    # TGT-279: sent-reply audit-trail storage now lives in
    # D2TG::Store::SentReplyAudit - built once here and reused by every
    # forwarding method below, same $dbh, no behavior change for any
    # existing caller, mirroring TGT-257/278's own precedent above.
    $self->{sent_reply_audit} = D2TG::Store::SentReplyAudit->new( dbh => $dbh );

    if ( defined $args{admin_chat_id} ) {
        my @ids = ref $args{admin_chat_id} eq 'ARRAY' ? @{ $args{admin_chat_id} } : ( $args{admin_chat_id} );
        for my $id (@ids) {
            if ( ref $id eq 'HASH' ) {
                $self->{access}->seed_admin( $id->{chat_id}, bot_key => $id->{bot_key} );
            }
            else {
                $self->{access}->seed_admin($id);
            }
        }
    }

    return $self;
}

# TGT-280 (own follow-up filed by TGT-279's survey): schema/migration
# DDL logic moved into D2TG::Store::Schema (a single ensure_schema($dbh)
# function, called directly above in new() rather than via a $self->
# instance method - unlike the DBI-handle-wrapper clusters, it needs no
# state of its own between calls). See D2TG::Store::Schema's own POD
# for the full migration history each block documents.

# TGT-279: access-control storage moved into D2TG::Store::AccessControl
# (built once in new() above, sharing this same $dbh) - these four
# methods are now thin forwarders so every existing caller keeps
# working unchanged via $store->method_name(...), mirroring TGT-257/278's
# own retry_queue/history forwarders. See D2TG::Store::AccessControl's
# own POD for the full behavior each one documents.
# TGT-297: AccessControl.pm's own is_allowed/add_pending/approve now
# take %args-style bot_key (matching its sibling modules), while this
# public forwarder's own signature stays positional for every existing
# caller (cli/approve.pl, D2TG::Poller::Dispatch, the whole test suite)
# - translate here, not at every call site.
sub is_allowed        { my ( $self, $chat_id, $bot_key ) = @_; return $self->{access}->is_allowed( $chat_id, bot_key => $bot_key ) }
sub add_pending       { my ( $self, $chat_id, $bot_key ) = @_; return $self->{access}->add_pending( $chat_id, bot_key => $bot_key ) }
sub approve           { my ( $self, $chat_id, $bot_key ) = @_; return $self->{access}->approve( $chat_id, bot_key => $bot_key ) }
sub pending_chat_ids  { my $self = shift; return $self->{access}->pending_chat_ids(@_) }

sub _offset_meta_key {
    my ($bot_key) = @_;
    return 'offset' unless defined $bot_key;
    return 'offset:' . sha256_hex($bot_key);
}

sub get_offset {
    my ( $self, $bot_key ) = @_;

    my ($value) = $self->{dbh}->selectrow_array(
        'SELECT value FROM meta WHERE key = ?', undef, _offset_meta_key($bot_key),
    );

    return defined $value ? $value : undef;
}

sub set_offset {
    my ( $self, $offset, $bot_key ) = @_;

    $self->{dbh}->do(
        'INSERT INTO meta (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        undef, _offset_meta_key($bot_key), $offset,
    );

    return;
}

# TGT-278: message-history storage moved into D2TG::Store::History
# (built once in new() above, sharing this same $dbh) - these eight
# methods are now thin forwarders so every existing caller keeps
# working unchanged via $store->method_name(...), mirroring TGT-257's
# own retry_queue forwarders below. See D2TG::Store::History's own POD
# for the full behavior each one documents.
sub record_message      { my $self = shift; return $self->{history}->record_message(@_) }
sub get_message          { my $self = shift; return $self->{history}->get_message(@_) }
sub get_attachment_path  { my $self = shift; return $self->{history}->get_attachment_path(@_) }
sub mark_read            { my $self = shift; return $self->{history}->mark_read(@_) }
sub is_read              { my $self = shift; return $self->{history}->is_read(@_) }
sub unread_messages      { my $self = shift; return $self->{history}->unread_messages(@_) }
sub recent_messages      { my $self = shift; return $self->{history}->recent_messages(@_) }
sub messages_in_range    { my $self = shift; return $self->{history}->messages_in_range(@_) }

# TGT-257: failed_downloads/failed_transcriptions storage moved into
# D2TG::Store::RetryQueue (built once in new() above, sharing this same
# $dbh) - these ten methods are now thin forwarders so every existing
# caller (cli/retry-download.pl, cli/unread.pl, cli/poller.pl,
# D2TG::Download, D2TG::Transcribe, and their tests) keeps working
# unchanged via $store->method_name(...). See D2TG::Store::RetryQueue's
# own POD for the full behavior each one documents.
sub record_failed_download          { my $self = shift; return $self->{retry_queue}->record_failed_download(@_) }
sub failed_downloads                { my $self = shift; return $self->{retry_queue}->failed_downloads(@_) }
sub failed_downloads_due_for_retry  { my $self = shift; return $self->{retry_queue}->failed_downloads_due_for_retry(@_) }
sub mark_failed_download_retried    { my $self = shift; return $self->{retry_queue}->mark_failed_download_retried(@_) }
sub remove_failed_download          { my $self = shift; return $self->{retry_queue}->remove_failed_download(@_) }
sub mark_failed_download_downloaded { my $self = shift; return $self->{retry_queue}->mark_failed_download_downloaded(@_) }
sub has_failed_download              { my $self = shift; return $self->{retry_queue}->has_failed_download(@_) }
sub record_failed_transcription         { my $self = shift; return $self->{retry_queue}->record_failed_transcription(@_) }
sub failed_transcriptions               { my $self = shift; return $self->{retry_queue}->failed_transcriptions(@_) }
sub remove_failed_transcription         { my $self = shift; return $self->{retry_queue}->remove_failed_transcription(@_) }
sub failed_transcriptions_due_for_retry { my $self = shift; return $self->{retry_queue}->failed_transcriptions_due_for_retry(@_) }
sub mark_failed_transcription_retried   { my $self = shift; return $self->{retry_queue}->mark_failed_transcription_retried(@_) }
sub has_failed_transcription            { my $self = shift; return $self->{retry_queue}->has_failed_transcription(@_) }
sub mark_failed_transcription_transcribed { my $self = shift; return $self->{retry_queue}->mark_failed_transcription_transcribed(@_) }

# TGT-279: sent-reply audit-trail storage moved into
# D2TG::Store::SentReplyAudit (built once in new() above, sharing this
# same $dbh) - these four methods are now thin forwarders so every
# existing caller keeps working unchanged via $store->method_name(...),
# mirroring TGT-257/278's own retry_queue/history forwarders. See
# D2TG::Store::SentReplyAudit's own POD for the full behavior each one
# documents.
sub record_sent_text          { my $self = shift; return $self->{sent_reply_audit}->record_sent_text(@_) }
sub record_sent_voice         { my $self = shift; return $self->{sent_reply_audit}->record_sent_voice(@_) }
sub text_only_replies         { my $self = shift; return $self->{sent_reply_audit}->text_only_replies(@_) }
sub is_recent_duplicate_reply { my $self = shift; return $self->{sent_reply_audit}->is_recent_duplicate_reply(@_) }

# TGT-235: unlike D2TG::Download::prune_vault, which already caps the
# attachments vault's own disk usage by byte count, the messages and
# sent_replies tables had no retention/eviction policy at all - every
# row was kept forever. Mirrors prune_vault's own pattern: an
# age-based cap, silent no-op when nothing is past the window,
# configurable via an optional argument with a sane default.
sub prune_history {
    my ( $self, %args ) = @_;
    my $days = $args{retention_days} // DEFAULT_RETENTION_DAYS;

    $self->{dbh}->do(
        "DELETE FROM messages WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$days days",
    );
    $self->{dbh}->do(
        "DELETE FROM sent_replies WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$days days",
    );

    # TGT-238: failed_downloads/failed_transcriptions are pure retry
    # queues with no other eviction path - a row is removed only by a
    # successful retry, so a permanently-unretryable row (an expired
    # Telegram file_id, say) would otherwise sit forever. A separate
    # (shorter) default window from messages/sent_replies above, since
    # this is about not cluttering a retry queue, not history retention.
    my $failed_queue_days = $args{failed_queue_retention_days} // DEFAULT_FAILED_QUEUE_RETENTION_DAYS;

    $self->{dbh}->do(
        "DELETE FROM failed_downloads WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$failed_queue_days days",
    );
    $self->{dbh}->do(
        "DELETE FROM failed_transcriptions WHERE datetime(created_at) < datetime('now', ?)",
        undef, "-$failed_queue_days days",
    );

    return;
}

sub disconnect {
    my ($self) = @_;

    $self->{dbh}->disconnect;

    return;
}

1;
