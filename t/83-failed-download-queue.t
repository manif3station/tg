use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use HTTP::Response;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Store;
require D2TG::Config;
require D2TG::Poller;
require D2TG::Download;
require Fake::Telegram;
require Fake::Store;

# Reuses the exact Fake::Telegram/Fake::UA shape t/41 already defines
# for D2TG::Download::download_file - a get_file/file_download_url
# double, plus a queued-responses HTTP client double.
package Fake::DownloadTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path} }, $class;
}

sub get_file {
    my ( $self, $file_id ) = @_;
    return $self->{file_path};
}

sub file_download_url {
    my ( $self, $file_path ) = @_;
    return "https://api.telegram.org/file/bottest-token/$file_path";
}

package Fake::UA;

sub new {
    my ( $class, %args ) = @_;
    return bless { responses => $args{responses} || [] }, $class;
}

sub get {
    my ($self) = @_;
    return shift @{ $self->{responses} };
}

package main;

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

# TGT-104 (user-supplied feature-gap analysis, /tmp/missing.md): the old
# ~/skills/tg blueprint kept a small on-disk queue recording which
# message and Telegram's own internal file handle failed to download (a
# transient network hiccup mid-transfer) - this matters because
# Telegram's Bot API file handles expire a limited time after the
# message arrives, after which the file is permanently unrecoverable.
# The new d2 tg.* skill reported a download failure once and moved on -
# no queue, no retry. D2TG::Store::record_failed_download/
# failed_downloads/remove_failed_download restore that queue.

my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 1 );

is_deeply( $store->failed_downloads, [], 'failed_downloads starts empty' );

my $id1 = $store->record_failed_download(
    999, 42, 'AgACfile123',
    sender => 'ada', media_kind => 'document', caption_note => '',
    error  => 'HTTP request failed (status 500)',
);
ok( $id1, 'record_failed_download returns a truthy new row id' );

my $list = $store->failed_downloads;
is( scalar @$list, 1, 'one row after the first record_failed_download' );
is( $list->[0]{id},         $id1,            'row carries its own id' );
is( $list->[0]{chat_id},    999,             'row carries chat_id' );
is( $list->[0]{message_id}, 42,              'row carries message_id' );
is( $list->[0]{file_id},    'AgACfile123',   'row carries the Telegram file_id' );
is( $list->[0]{sender},     'ada',           'row carries the sender' );
is( $list->[0]{media_kind}, 'document',      'row carries the media_kind' );
is( $list->[0]{error},      'HTTP request failed (status 500)', 'row carries the original error' );
ok( $list->[0]{created_at}, 'row carries a created_at timestamp' );

my $id2 = $store->record_failed_download(
    1000, 7, 'AgACfile456',
    sender => 'bob', media_kind => 'photo', caption_note => '', error => 'timed out',
);
isnt( $id2, $id1, 'a second failed download (different chat/message) gets a distinct id' );
is( scalar @{ $store->failed_downloads }, 2, 'two rows now queued' );

# Codex review finding: Telegram's at-least-once delivery can reprocess
# the same update - recording the same (chat_id, message_id) again must
# refresh the existing row, never insert a duplicate.
my $id1_again = $store->record_failed_download(
    999, 42, 'AgACfile123-retry',
    sender => 'ada', media_kind => 'document', caption_note => '',
    error  => 'a second, different failure',
);
is( $id1_again, $id1, 'redelivering the same (chat_id, message_id) reuses the existing row id' );
is( scalar @{ $store->failed_downloads }, 2, 'still only two rows queued after the redelivery' );
my ($refreshed) = grep { $_->{id} == $id1 } @{ $store->failed_downloads };
is( $refreshed->{file_id}, 'AgACfile123-retry',       'the redelivered row\'s file_id is refreshed' );
is( $refreshed->{error},   'a second, different failure', 'the redelivered row\'s error is refreshed' );

$store->remove_failed_download($id1);
my $after_remove = $store->failed_downloads;
is( scalar @$after_remove, 1, 'remove_failed_download removes exactly the given row' );
is( $after_remove->[0]{id}, $id2, 'the remaining row is the one not removed' );

$store->remove_failed_download($id1);    # already removed - must not die
is( scalar @{ $store->failed_downloads }, 1, 'removing an already-removed id is a harmless no-op' );

# Poller-level wiring: a genuine download failure with a store present
# gets queued, not just printed and discarded.
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 401,
                message   => { message_id => 41, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-fails' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { die "network unreachable\n"; };

    capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    my $queued = $store->failed_downloads;
    is( scalar @$queued, 1, 'a download failure with a store present is queued exactly once' );
    is( $queued->[0]{chat_id},    999,           'queued entry carries the chat_id' );
    is( $queued->[0]{file_id},    'doc-fails',   'queued entry carries the Telegram file_id' );
    like( $queued->[0]{error},    qr/network unreachable/, 'queued entry carries the original error' );
}

{
    # Codex review finding: a queue-write failure (e.g. a locked/full
    # SQLite database) must not turn an already-reported, already-
    # non-fatal media download failure into a poll-cycle failure -
    # run_once must still complete and return normally.
    package Fake::Store::FailsToRecord;
    our @ISA = ('Fake::Store');
    sub record_failed_download { die "database is locked\n"; }

    package main;

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 403,
                message   => { message_id => 43, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-fails-2' } },
            },
        ],
    );
    my $store = Fake::Store::FailsToRecord->new( allowed => [999] );
    my $download_media = sub { die "network unreachable\n"; };

    my ( $out, $err, $offset );
    ( $out, $err ) = capture_std( sub {
        $offset = D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    ok( defined $offset, 'run_once still completes and returns an offset when the queue write itself fails' );
    like( $err, qr/failed to queue for retry too: database is locked/, 'the queue-write failure is reported on stderr, not thrown' );
}

{
    # Regression: a SUCCESSFUL download must never be queued.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 402,
                message   => { message_id => 42, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-ok' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { return '/tmp/doc-ok.bin'; };

    capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    is_deeply( $store->failed_downloads, [], 'a successful download is never queued as failed' );
}

# TGT-104: distinguish a PERMANENTLY-gone Telegram file_id from an
# ordinary, still-retryable download failure.
{
    ok( D2TG::Config::is_expired_file_error('D2TG::Telegram getFile failed: Bad Request: file is no longer available'),
        'recognizes "file is no longer available" as permanently expired' );
    ok( D2TG::Config::is_expired_file_error('D2TG::Telegram getFile failed: Bad Request: wrong file_id'),
        'recognizes "wrong file_id" as permanently expired' );

    # Codex review finding: "temporarily unavailable" describes a real
    # transient condition that CAN still succeed on a later retry - an
    # earlier draft wrongly classified it as permanent, which would
    # have told an operator to give up on something that might work.
    ok( !D2TG::Config::is_expired_file_error('D2TG::Telegram getFile failed: Bad Request: file is temporarily unavailable'),
        '"file is temporarily unavailable" is NOT classified as permanently expired' );

    ok( !D2TG::Config::is_expired_file_error('D2TG::Download::download_file: HTTP request failed (status 500)'),
        'an ordinary transient HTTP failure is not classified as expired' );
    ok( !D2TG::Config::is_expired_file_error('network unreachable'),
        'an unrelated error is not classified as expired' );
    ok( !D2TG::Config::is_expired_file_error(undef),
        'undef is not classified as expired' );
}

# D2TG::Download::retry_failed_download: a successful retry restores
# the message into history AND removes the queue row (Codex review
# finding - the original design only did the latter).
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    my $id = $store->record_failed_download(
        999, 55, 'AABBqueued',
        sender => 'ada', media_kind => 'document', caption_note => ' (my receipt)',
        error  => 'HTTP request failed (status 500)',
    );
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_downloads };

    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_1.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('recovered file bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    my ( $ok, $local_path ) = D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );

    ok( $ok, 'retry_failed_download reports success' );
    like( $local_path, qr/\.pdf$/, 'returns the newly downloaded local path' );

    is_deeply( $store->failed_downloads, [], 'the queue row is removed after a successful retry' );

    my $restored = $store->get_message( 999, 55 );
    ok( $restored, 'the message is restored into D2TG::Store history on a successful retry' );
    is( $restored->{sender}, 'ada', 'restored message carries the original sender' );
    like( $restored->{summary}, qr/^document \Q$local_path\E \(my receipt\)$/, 'restored message summary matches the original success-path shape' );
}

{
    # A failed retry must leave the queue row completely untouched.
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    my $id = $store->record_failed_download(
        999, 56, 'AABBfails',
        sender => 'ada', media_kind => 'document', caption_note => '',
        error  => 'HTTP request failed (status 500)',
    );
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_downloads };

    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_2.pdf' );
    my $response = HTTP::Response->new( 500, 'Internal Server Error' );
    my $ua = Fake::UA->new( responses => [$response] );

    my ( $ok, $error ) = D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );

    ok( !$ok, 'retry_failed_download reports failure' );
    like( $error, qr/status 500/, 'returns the underlying error' );

    is( scalar @{ $store->failed_downloads }, 1, 'the queue row is left untouched after a failed retry' );
    is( $store->get_message( 999, 56 ), undef, 'no message is restored on a failed retry' );
}

# CLI-level: d2 tg.retry-download lists and retries the real queue.
{
    my $cli         = File::Spec->catfile( $Bin, '..', 'cli', 'retry-download.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    {
        my $out = `$cli`;
        is( $out, "No failed downloads queued.\n", 'lists nothing when the queue is empty' );
    }

    {
        my $store = D2TG::Store->new(
            db_path       => File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.messages.db' ),
            admin_chat_id => 12345,
        );
        $store->record_failed_download(
            999, 42, 'AgACqueued',
            sender => 'ada', media_kind => 'document', caption_note => '',
            error  => 'HTTP request failed (status 500)',
        );
        $store->disconnect;

        my $out = `$cli`;
        like( $out, qr/chat_id=999/,             'lists the queued chat_id' );
        like( $out, qr/message_id=42/,           'lists the queued message_id' );
        like( $out, qr/file_id=AgACqueued/,      'lists the queued file_id' );
        like( $out, qr/status 500/,              'lists the original error' );
    }

    {
        my ( $out, $rc ) = ( `$cli 999999 2>&1`, $? >> 8 );
        isnt( $rc, 0, 'retrying an unknown id exits non-zero' );
        like( $out, qr/No queued failed download with id 999999/, 'names the unknown id' );
    }

    {
        my ( $out, $rc ) = ( `$cli 1 2 2>&1`, $? >> 8 );
        isnt( $rc, 0, 'too many positional arguments refuses' );
        like( $out, qr/Usage/, 'usage refusal names the correct usage' );
    }

    # Queue must still have exactly the one row from above - none of
    # the failed lookups/refusals should have mutated it.
    {
        my $store = D2TG::Store->new(
            db_path       => File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.messages.db' ),
            admin_chat_id => 12345,
        );
        is( scalar @{ $store->failed_downloads }, 1, 'the queue is unaffected by unknown-id/usage refusals' );
        $store->disconnect;
    }
}

done_testing();
