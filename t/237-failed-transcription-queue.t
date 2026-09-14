use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Store;
require D2TG::Poller;
require D2TG::Download;
require D2TG::Transcribe;
require Fake::Telegram;
require Fake::Store;

# TGT-237 (found via a scheduled JOB-003 hourly bug hunt): D2TG::Poller's
# voice transcription branch had no analogue of the photo/document
# branch's failed_downloads queue - a transcribe_voice failure was
# printed to STDERR (TRANSCRIBE ERROR) only and permanently lost, with
# no retry path, unlike D2TG::Store::failed_downloads/
# d2 tg.retry-download (TGT-104). New failed_transcriptions
# table/methods and D2TG::Download::retry_failed_transcription mirror
# that established pattern.

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    open my $err_fh, '>', \$err or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

# D2TG::Store: the new queue table/methods, mirroring failed_downloads.
{
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 1 );

    is_deeply( $store->failed_transcriptions, [], 'failed_transcriptions starts empty' );

    my $id1 = $store->record_failed_transcription(
        999, 42, 'AgACvoice123',
        sender => 'ada', error => 'whisper: no such file or directory',
    );
    ok( $id1, 'record_failed_transcription returns a truthy new row id' );

    my $list = $store->failed_transcriptions;
    is( scalar @$list, 1, 'one row after the first record_failed_transcription' );
    is( $list->[0]{chat_id},    999,             'row carries chat_id' );
    is( $list->[0]{message_id}, 42,              'row carries message_id' );
    is( $list->[0]{file_id},    'AgACvoice123',  'row carries the Telegram file_id' );
    is( $list->[0]{sender},     'ada',           'row carries the sender' );
    like( $list->[0]{error}, qr/whisper/,        'row carries the original error' );
    ok( $list->[0]{created_at}, 'row carries a created_at timestamp' );

    # Redelivery refreshes, never duplicates - matching failed_downloads.
    my $id1_again = $store->record_failed_transcription(
        999, 42, 'AgACvoice123-retry',
        sender => 'ada', error => 'a second failure',
    );
    is( $id1_again, $id1, 'redelivering the same (chat_id, message_id) reuses the existing row id' );
    is( scalar @{ $store->failed_transcriptions }, 1, 'still only one row queued after redelivery' );

    $store->remove_failed_transcription($id1);
    is_deeply( $store->failed_transcriptions, [], 'remove_failed_transcription removes the row' );
    $store->remove_failed_transcription($id1);    # already removed - must not die
}

# bot_key scoping: multi-bot isolation, matching failed_downloads' own
# TGT-219 precedent.
{
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 1 );

    $store->record_failed_transcription( 999, 42, 'file-a', sender => 'ada', error => 'e1', bot_key => 'tokenA' );
    $store->record_failed_transcription( 999, 42, 'file-b', sender => 'ada', error => 'e2', bot_key => 'tokenB' );

    is( scalar @{ $store->failed_transcriptions }, 2, 'the same (chat_id, message_id) under two bots queues two independent rows' );
    is( scalar @{ $store->failed_transcriptions( bot_key => 'tokenA' ) }, 1, 'bot_key filter scopes to just that bot' );
    is( $store->failed_transcriptions( bot_key => 'tokenA' )->[0]{file_id}, 'file-a', 'the filtered row is the right bot\'s own' );
}

# Poller-level wiring: a genuine transcription failure with a store
# present gets queued AND is visible on STDOUT, not just STDERR.
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 401,
                message   => { message_id => 41, chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'voice-fails' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $transcribe_voice = sub { die "whisper binary not found\n"; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    my $queued = $store->failed_transcriptions;
    is( scalar @$queued, 1, 'a transcription failure with a store present is queued exactly once' );
    is( $queued->[0]{chat_id}, 999,           'queued entry carries the chat_id' );
    is( $queued->[0]{file_id}, 'voice-fails', 'queued entry carries the Telegram file_id' );
    like( $queued->[0]{error}, qr/whisper binary not found/, 'queued entry carries the original error' );

    like( $out, qr/NEW TG VOICE FAILED/, 'STDOUT carries a visibility line, reaching the monitor bridge (TGT-204 precedent)' );
    like( $out, qr/retry-transcription/, 'STDOUT names the recovery command' );
}

{
    # Regression: a SUCCESSFUL transcription must never be queued.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 402,
                message   => { message_id => 42, chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'voice-ok' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $transcribe_voice = sub { return 'hello there'; };

    capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    is_deeply( $store->failed_transcriptions, [], 'a successful transcription is never queued as failed' );
}

{
    # A queue-write failure must not turn an already-non-fatal
    # transcription failure into a poll-cycle failure.
    package Fake::Store::FailsToRecordTranscription;
    our @ISA = ('Fake::Store');
    sub record_failed_transcription { die "database is locked\n"; }

    package main;

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 403,
                message   => { message_id => 43, chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'voice-fails-2' } },
            },
        ],
    );
    my $store = Fake::Store::FailsToRecordTranscription->new( allowed => [999] );
    my $transcribe_voice = sub { die "whisper crashed\n"; };

    my ( $out, $err, $offset );
    ( $out, $err ) = capture_std( sub {
        $offset = D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    ok( defined $offset, 'run_once still completes and returns an offset when the queue write itself fails' );
    like( $err, qr/failed to queue for retry too: database is locked/, 'the queue-write failure is reported on stderr, not thrown' );
}

# D2TG::Download::retry_failed_transcription: a successful retry
# restores the message into history AND removes the queue row.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    my $id = $store->record_failed_transcription(
        999, 55, 'AABBqueued', sender => 'ada', error => 'whisper crashed',
    );
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };

    no warnings 'once';
    local *D2TG::Download::download_file = sub { return '/tmp/does-not-matter-tgt237.oga' };
    local *D2TG::Transcribe::transcribe  = sub { return 'recovered transcript' };

    my ( $ok, $transcript ) = D2TG::Download::retry_failed_transcription( 'fake-telegram', $store, $row );

    ok( $ok, 'retry_failed_transcription reports success' );
    is( $transcript, 'recovered transcript', 'returns the newly transcribed text' );
    is_deeply( $store->failed_transcriptions, [], 'the queue row is removed after a successful retry' );

    my $restored = $store->get_message( 999, 55 );
    ok( $restored, 'the message is restored into D2TG::Store history on a successful retry' );
    is( $restored->{summary}, 'recovered transcript', 'restored message summary is the transcript itself' );
}

{
    # A failed retry must leave the queue row completely untouched.
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    my $id = $store->record_failed_transcription(
        999, 56, 'AABBfails', sender => 'ada', error => 'whisper crashed',
    );
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };

    local *D2TG::Download::download_file = sub { die "still unreachable\n" };

    my ( $ok, $error ) = D2TG::Download::retry_failed_transcription( 'fake-telegram', $store, $row );

    ok( !$ok, 'retry_failed_transcription reports failure' );
    like( $error, qr/still unreachable/, 'returns the underlying error' );
    is( scalar @{ $store->failed_transcriptions }, 1, 'the queue row is left untouched after a failed retry' );
    is( $store->get_message( 999, 56 ), undef, 'no message is restored on a failed retry' );
}

{
    # A successful download but a failed transcription must also leave
    # the queue row untouched, and must not restore any message.
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    my $id = $store->record_failed_transcription(
        999, 57, 'AABBtranscribefails', sender => 'ada', error => 'whisper crashed',
    );
    my ($row) = grep { $_->{id} == $id } @{ $store->failed_transcriptions };

    no warnings 'once';
    local *D2TG::Download::download_file = sub { return '/tmp/does-not-matter-tgt237-b.oga' };
    local *D2TG::Transcribe::transcribe  = sub { die "whisper still crashed\n" };

    my ( $ok, $error ) = D2TG::Download::retry_failed_transcription( 'fake-telegram', $store, $row );

    ok( !$ok, 'retry_failed_transcription reports failure when transcription itself fails after a successful download' );
    like( $error, qr/whisper still crashed/, 'returns the underlying transcription error' );
    is( scalar @{ $store->failed_transcriptions }, 1, 'the queue row is left untouched' );
    is( $store->get_message( 999, 57 ), undef, 'no message is restored' );
}

{
    # A successful transcription whose record_message write itself
    # fails must leave the queue row queued (not lost twice), matching
    # retry_failed_download's own established precedent.
    package Fake::Store::FailsToRecordMessage;

    sub new { return bless {}, shift }
    sub record_message { die "database is locked\n" }
    sub failed_transcriptions { return [] }
    sub remove_failed_transcription { }

    package main;

    my $store = Fake::Store::FailsToRecordMessage->new;
    my $row = { id => 99, chat_id => 999, message_id => 58, file_id => 'AABBrecordfails', sender => 'ada' };

    no warnings 'once';
    local *D2TG::Download::download_file = sub { return '/tmp/does-not-matter-tgt237-c.oga' };
    local *D2TG::Transcribe::transcribe  = sub { return 'a transcript that cannot be saved' };

    my ( $out, $err ) = ( '', '' );
    open my $err_fh, '>', \$err or die $!;
    local *STDERR = $err_fh;
    my ( $ok, $transcript ) = D2TG::Download::retry_failed_transcription( 'fake-telegram', $store, $row );
    close $err_fh;

    ok( $ok, 'retry_failed_transcription still reports success - the transcription itself succeeded' );
    is( $transcript, 'a transcript that cannot be saved', 'returns the transcript even though it could not be saved' );
    like( $err, qr/STORE ERROR.*queue row not removed/, 'a record_message failure is reported and the row is deliberately left queued' );
}

# CLI-level: d2 tg.retry-transcription lists and retries the real queue.
{
    my $cli         = File::Spec->catfile( $Bin, '..', 'cli', 'retry-transcription.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    {
        my $out = `$cli`;
        is( $out, "No failed transcriptions queued.\n", 'lists nothing when the queue is empty' );
    }

    {
        my $store = D2TG::Store->new(
            db_path       => File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.messages.db' ),
            admin_chat_id => 12345,
        );
        $store->record_failed_transcription(
            999, 42, 'AgACqueued', sender => 'ada', error => 'whisper crashed',
        );
        $store->disconnect;

        my $out = `$cli`;
        like( $out, qr/chat_id=999/,        'lists the queued chat_id' );
        like( $out, qr/message_id=42/,      'lists the queued message_id' );
        like( $out, qr/file_id=AgACqueued/, 'lists the queued file_id' );
        like( $out, qr/whisper crashed/,    'lists the original error' );
    }

    {
        my ( $out, $rc ) = ( `$cli 999999 2>&1`, $? >> 8 );
        isnt( $rc, 0, 'retrying an unknown id exits non-zero' );
        like( $out, qr/No queued failed transcription with id 999999/, 'names the unknown id' );
    }

    {
        my ( $out, $rc ) = ( `$cli 1 2 2>&1`, $? >> 8 );
        isnt( $rc, 0, 'too many positional arguments refuses' );
        like( $out, qr/Usage/, 'usage refusal names the correct usage' );
    }

    {
        my $store = D2TG::Store->new(
            db_path       => File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.messages.db' ),
            admin_chat_id => 12345,
        );
        is( scalar @{ $store->failed_transcriptions }, 1, 'the queue is unaffected by unknown-id/usage refusals' );
        $store->disconnect;
    }
}

done_testing();
