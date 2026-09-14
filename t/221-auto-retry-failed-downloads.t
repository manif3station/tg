use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use HTTP::Response;

require D2TG::Store;
require D2TG::Download;

# TGT-221 (Q-015 answered by Michael, 2026-09-14: retry every 60s for
# up to 5 minutes total, independent of poll cadence): TGT-204 made a
# queued failed_downloads row visible but explicitly deferred automatic
# recovery - a failed download sat queued until a human/agent ran
# 'd2 tg.retry-download' by hand. D2TG::Download::auto_retry_failed_downloads
# adds bounded, non-fatal automatic retry: a row due for retry (not
# retried in the last 60s, still within 5 minutes of being queued) is
# retried automatically; a persistently-failing row stops being
# auto-retried once 5 minutes have elapsed, but remains queued/visible
# for manual retry exactly as before.

package Fake::DownloadTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path} }, $class;
}

sub get_file      { my ( $self, $file_id ) = @_; return $self->{file_path}; }
sub file_download_url { my ( $self, $file_path ) = @_; return "https://api.telegram.org/file/bottest-token/$file_path"; }

package Fake::UA;

sub new { my ( $class, %args ) = @_; return bless { responses => $args{responses} || [] }, $class; }
sub get { my ($self) = @_; return shift @{ $self->{responses} }; }

package main;

# D2TG::Store: last_retry_at tracking + the due-for-retry query.
{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    my $id = $store->record_failed_download(
        1, 1, 'file-a', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e',
    );

    my @due = @{ $store->failed_downloads_due_for_retry };
    is( scalar @due, 1, 'a freshly-queued row (never auto-retried) is immediately due for retry' );
    is( $due[0]{id}, $id, 'the due row is the one just queued' );

    $store->mark_failed_download_retried($id);
    @due = @{ $store->failed_downloads_due_for_retry };
    is( scalar @due, 0, 'a row just retried is not due again immediately (within the 60s interval)' );

    $store->{dbh}->do(
        q{UPDATE failed_downloads SET last_retry_at = datetime('now', '-61 seconds') WHERE id = ?}, undef, $id,
    );
    @due = @{ $store->failed_downloads_due_for_retry };
    is( scalar @due, 1, 'a row last retried over 60s ago is due again' );

    $store->{dbh}->do(
        q{UPDATE failed_downloads SET created_at = datetime('now', '-301 seconds') WHERE id = ?}, undef, $id,
    );
    @due = @{ $store->failed_downloads_due_for_retry };
    is( scalar @due, 0, 'a row queued over 5 minutes ago is no longer due for auto-retry (outside the window)' );

    my $list = $store->failed_downloads;
    is( scalar @$list, 1, 'the row is still queued and visible even though auto-retry has given up on it' );
}

# D2TG::Download::auto_retry_failed_downloads: a successful retry
# removes the row, exactly like a manual retry_failed_download would.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    $store->record_failed_download(
        999, 55, 'AABBqueued', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e',
    );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_1.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('recovered file bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    D2TG::Download::auto_retry_failed_downloads( $telegram, $store, $dir, ua => $ua );

    is_deeply( $store->failed_downloads, [], 'a successfully auto-retried row is removed from the queue' );
    ok( $store->get_message( 999, 55 ), 'the message is restored into history on a successful auto-retry' );
}

# A failed auto-retry attempt updates last_retry_at and leaves the row
# queued - never crashes the caller.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    my $id = $store->record_failed_download(
        999, 56, 'AABBfails', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e',
    );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_2.pdf' );
    my $response = HTTP::Response->new( 500, 'Internal Server Error' );
    my $ua = Fake::UA->new( responses => [$response] );

    my $ok = eval { D2TG::Download::auto_retry_failed_downloads( $telegram, $store, $dir, ua => $ua ); 1 };
    ok( $ok, 'auto_retry_failed_downloads never dies, even when the underlying retry fails' );

    my ($row) = @{ $store->failed_downloads };
    ok( $row, 'the row is still queued after a failed auto-retry attempt' );
    ok( $row->{last_retry_at}, 'last_retry_at is updated after the failed attempt' );

    my @due = @{ $store->failed_downloads_due_for_retry };
    is( scalar @due, 0, 'immediately after a failed attempt, the row is not due again until the 60s interval elapses' );
}

# bot_key scoping: only the given bot's own queue is auto-retried.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new(
        db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
        admin_chat_id => 1,
    );
    $store->record_failed_download( 1, 1, 'file-a', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e', bot_key => 'tokenA' );
    $store->record_failed_download( 1, 2, 'file-b', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e', bot_key => 'tokenB' );

    my @due = @{ $store->failed_downloads_due_for_retry( bot_key => 'tokenA' ) };
    is( scalar @due, 1, 'bot_key filter scopes the due-for-retry listing to just that bot' );
    is( $due[0]{bot_key}, 'tokenA', 'the filtered row belongs to the requested bot' );
}

done_testing();
