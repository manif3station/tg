use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use HTTP::Response;
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Store;
require D2TG::Download;

# TGT-196 (Michael's own design choice, Q-013, answering a Codex
# documentation-stage review finding on TGT-194: a persistently-failing
# record_message used to re-download the same already-fetched file on
# every retry pass, forever, wasting bandwidth/Telegram API calls with
# no escape hatch). A record_message failure now persists the
# already-downloaded local_path on the queued row via
# D2TG::Store::mark_failed_download_downloaded; a future retry sees it
# and skips download_file entirely, retrying only the still-failing
# record_message write.

sub fresh_db_path {
    my $dir = tempdir( CLEANUP => 1 );
    return File::Spec->catfile( $dir, 'store.sqlite' );
}

package Fake::DownloadTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path}, get_file_calls => 0 }, $class;
}

sub get_file {
    my ( $self, $file_id ) = @_;
    $self->{get_file_calls}++;
    return $self->{file_path};
}

sub file_download_url {
    my ( $self, $file_path ) = @_;
    return "https://api.telegram.org/file/bottest-token/$file_path";
}

package Fake::UA;

sub new { my ( $class, %args ) = @_; return bless { responses => $args{responses} || [] }, $class; }
sub get { my ($self) = @_; return shift @{ $self->{responses} }; }

package main;

{
    # First retry attempt: download succeeds, record_message fails.
    # local_path must be persisted on the row.
    my $dir      = tempdir( CLEANUP => 1 );
    my $store    = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id       = $store->record_failed_download(
        999, 77, 'AABBescape',
        sender => 'ada', media_kind => 'document', caption_note => '',
        error  => 'HTTP request failed (status 500)',
    );

    # Force record_message to fail by closing the underlying dbh - the
    # simplest way to make a real D2TG::Store call die predictably
    # without a fake double, since this test wants the REAL schema/
    # persistence behavior of mark_failed_download_downloaded exercised
    # end to end, not a mocked one.
    package Fake::Store::DyingRecordMessage;
    our @ISA = ('D2TG::Store');
    sub record_message { die "database is locked\n"; }
    package main;
    bless $store, 'Fake::Store::DyingRecordMessage';

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_downloads };
    ok( !defined $row->{local_path}, 'row starts with no local_path - ordinary not-yet-downloaded state' );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/escape.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('escape hatch bytes');
    my $ua = Fake::UA->new( responses => [$response] );

    my $err = '';
    {
        open my $fh, '>', \$err or die $!;
        local *STDERR = $fh;
        D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );
        close $fh;
    }

    is( $telegram->{get_file_calls}, 1, 'first attempt: download_file is genuinely attempted once' );
    like( $err, qr/STORE ERROR \[999\]: record_message failed/, 'record_message failure logged non-fatally' );

    my ($row_after) = grep { $_->{id} == $id } @{ $store->failed_downloads };
    ok( defined $row_after->{local_path}, 'local_path is now persisted on the row after the failed retry' );
    like( $row_after->{local_path}, qr/\.pdf$/, 'the persisted local_path is the genuinely downloaded file' );

    # Second retry attempt on the SAME still-queued row: download_file
    # must NOT be attempted again - only record_message is retried.
    my $telegram2 = Fake::DownloadTelegram->new( file_path => 'documents/escape.pdf' );
    my $err2      = '';
    {
        open my $fh, '>', \$err2 or die $!;
        local *STDERR = $fh;
        D2TG::Download::retry_failed_download( $telegram2, $store, $row_after, $dir, ua => Fake::UA->new );
        close $fh;
    }

    is( $telegram2->{get_file_calls}, 0, 'second attempt: download_file is NOT attempted again - the escape hatch works' );
    like( $err2, qr/STORE ERROR \[999\]: record_message failed/, 'record_message failure is still logged (still failing) - no re-download attempted' );
}

{
    # Once record_message eventually succeeds, the row is removed as
    # normal, whether or not local_path was already persisted.
    my $dir   = tempdir( CLEANUP => 1 );
    my $store = D2TG::Store->new( db_path => fresh_db_path(), admin_chat_id => 1 );
    my $id    = $store->record_failed_download(
        999, 78, 'AABBrecover',
        sender => 'ada', media_kind => 'document', caption_note => '',
        error  => 'HTTP request failed (status 500)',
    );
    $store->mark_failed_download_downloaded( $id, '/tmp/pre-downloaded-file.pdf' );

    my ($row) = grep { $_->{id} == $id } @{ $store->failed_downloads };
    is( $row->{local_path}, '/tmp/pre-downloaded-file.pdf', 'local_path was set directly for this test' );

    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/unused.pdf' );
    my ( $ok, $result ) = D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => Fake::UA->new );

    is( $telegram->{get_file_calls}, 0, 'download_file is skipped - the persisted local_path is reused directly' );
    ok( $ok, 'retry_failed_download reports success once record_message succeeds' );
    is( $result, '/tmp/pre-downloaded-file.pdf', 'the returned local_path is the persisted one, not a freshly downloaded one' );
    is_deeply( $store->failed_downloads, [], 'the queue row is removed once record_message finally succeeds' );

    my $restored = $store->get_message( 999, 78 );
    ok( $restored, 'the message is restored into history' );
}

done_testing();
