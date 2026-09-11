use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use HTTP::Response;
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Download;
require D2TG::Poller;

# TGT-194 (found via a scheduled JOB-003 hourly bug hunt, reproduced
# live in a developer-dashboard:latest container, the same class of
# issue as TGT-132/165/166/186/190/191/192/193): D2TG::Download::
# retry_failed_download calls $store->record_message(...) and
# $store->remove_failed_download(...) directly, with no eval/
# classification around either call. If either dies (e.g. a locked/
# busy database), the exception propagates raw straight out of
# retry_failed_download, breaking its own documented
# (1, $local_path)/(0, $error) return contract, and - since
# cli/retry-download.pl's own batch loop has no eval around the call
# either - crashing the whole script mid-loop, silently abandoning
# every remaining queued row in that batch.

sub capture_stderr {
    my ($code) = @_;
    my $err = '';
    open my $fh, '>', \$err or die $!;
    local *STDERR = $fh;
    my @result = $code->();
    close $fh;
    return ( $err, @result );
}

package Fake::DownloadTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path} }, $class;
}

sub get_file          { my ( $self, $file_id ) = @_; return $self->{file_path}; }
sub file_download_url { my ( $self, $file_path ) = @_; return "https://api.telegram.org/file/bottest-token/$file_path"; }

package Fake::UA;

sub new { my ( $class, %args ) = @_; return bless { responses => $args{responses} || [] }, $class; }
sub get { my ($self) = @_; return shift @{ $self->{responses} }; }

package Fake::Store::DyingRecordMessage;

# dies_for (a message_id), when given, dies only for that specific
# message_id and succeeds for every other one - lets one store
# instance be reused across multiple rows in a single test, proving
# real per-row isolation on the SAME store rather than merely on two
# separate store instances.
sub new {
    my ( $class, %args ) = @_;
    return bless { calls => [], dies_for => $args{dies_for} }, $class;
}

sub record_message {
    my ( $self, $chat_id, $message_id, @rest ) = @_;
    push @{ $self->{calls} }, [ 'record_message', $chat_id, $message_id, @rest ];
    die "database is locked\n"
      if !defined $self->{dies_for} || $message_id == $self->{dies_for};
    return;
}

sub remove_failed_download {
    my $self = shift;
    push @{ $self->{calls} }, [ 'remove_failed_download', @_ ];
    return;
}

package Fake::Store::DyingRemoveFailedDownload;

sub new { return bless { calls => [] }, shift; }

sub record_message {
    my $self = shift;
    push @{ $self->{calls} }, [ 'record_message', @_ ];
    return;
}

sub remove_failed_download {
    my $self = shift;
    push @{ $self->{calls} }, [ 'remove_failed_download', @_ ];
    die "database is locked\n";
}

package main;

{
    # record_message dies mid-retry - the download itself genuinely
    # succeeded, so this must not be reported as a download failure;
    # the caller still gets (1, $local_path), with the store failure
    # logged non-fatally to STDERR, classified (never the raw
    # exception).
    my $dir      = tempdir( CLEANUP => 1 );
    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_1.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('recovered file bytes');
    my $ua    = Fake::UA->new( responses => [$response] );
    my $store = Fake::Store::DyingRecordMessage->new;
    my $row   = { id => 1, chat_id => 999, message_id => 55, file_id => 'AABBqueued', sender => 'ada', media_kind => 'document', caption_note => '' };

    my ( $err, $ok, $result ) = capture_stderr( sub {
        return D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );
    } );

    ok( $ok, 'retry_failed_download still reports success - the download itself genuinely succeeded' );
    like( $result, qr/\.pdf$/, 'still returns the newly downloaded local path' );
    like( $err, qr/STORE ERROR \[999\]: record_message failed - database is locked/,
        'the record_message failure is logged non-fatally, classified (never the raw exception)' );
    unlike( $err, qr/at \S+\.pm line \d+/, 'the raw exception trace is never echoed - only the classified reason (TGT-133 precedent)' );
    # A Codex documentation-stage review finding: removing the queue
    # row unconditionally here, even though record_message itself
    # failed, would leave a message with NEITHER a queue row NOR a
    # history record - worse than the pre-fix crash (which at least
    # left the row queued, since the raw die happened before
    # remove_failed_download was ever reached). remove_failed_download
    # must NOT be attempted this cycle so the row survives for a
    # future retry that can still restore history.
    is_deeply( [ grep { $_->[0] eq 'remove_failed_download' } @{ $store->{calls} } ], [],
        'remove_failed_download is deliberately NOT attempted when record_message failed - the queue row survives for a future retry' );
    like( $err, qr/STORE ERROR \[999\]: queue row not removed/,
        'a clear note explains why the row was left queued' );
}

{
    # remove_failed_download dies mid-retry - same non-fatal guarantee.
    my $dir      = tempdir( CLEANUP => 1 );
    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_2.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('recovered file bytes');
    my $ua    = Fake::UA->new( responses => [$response] );
    my $store = Fake::Store::DyingRemoveFailedDownload->new;
    my $row   = { id => 2, chat_id => 999, message_id => 56, file_id => 'AABBqueued2', sender => 'ada', media_kind => 'document', caption_note => '' };

    my ( $err, $ok, $result ) = capture_stderr( sub {
        return D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );
    } );

    ok( $ok, 'retry_failed_download still reports success when only remove_failed_download fails' );
    like( $result, qr/\.pdf$/, 'still returns the newly downloaded local path' );
    like( $err, qr/STORE ERROR \[999\]: remove_failed_download failed - database is locked/,
        'the remove_failed_download failure is logged non-fatally, classified' );
    unlike( $err, qr/at \S+\.pm line \d+/, 'the raw exception trace is never echoed' );
}

{
    # No media_kind (a text-only queued row would never reach here in
    # practice, but the code path exists) - record_message is skipped
    # entirely, only remove_failed_download runs; that failure alone
    # must still be non-fatal.
    my $dir      = tempdir( CLEANUP => 1 );
    my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_3.pdf' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('recovered file bytes');
    my $ua    = Fake::UA->new( responses => [$response] );
    my $store = Fake::Store::DyingRemoveFailedDownload->new;
    my $row   = { id => 3, chat_id => 999, message_id => 57, file_id => 'AABBqueued3' };

    my ( $err, $ok, $result ) = capture_stderr( sub {
        return D2TG::Download::retry_failed_download( $telegram, $store, $row, $dir, ua => $ua );
    } );

    ok( $ok, 'retry_failed_download still reports success' );
    is_deeply( [ grep { $_->[0] eq 'record_message' } @{ $store->{calls} } ], [],
        'record_message is never attempted when media_kind is undef, as before this ticket' );
    like( $err, qr/STORE ERROR \[999\]: remove_failed_download failed - database is locked/,
        'remove_failed_download failure still logged non-fatally' );
}

# Per-row batch isolation: two consecutive calls on the ACTUAL SAME
# store instance (matching cli/retry-download.pl's own for-loop
# reusing one $store across every queued row) - the first row's
# store-write failure must not affect the second row's own
# independent success. A Codex documentation-stage review finding: an
# earlier draft of this block claimed to test this but silently used
# a second, different store instance for row 2 instead, so it never
# actually proved same-store isolation - fixed by giving the fake a
# dies_for(message_id) so one store instance can fail for row 1's
# message_id specifically while genuinely succeeding for row 2's.
{
    my $dir   = tempdir( CLEANUP => 1 );
    my $store = Fake::Store::DyingRecordMessage->new( dies_for => 1 );

    my $telegram1 = Fake::DownloadTelegram->new( file_path => 'documents/row1.pdf' );
    my $response1 = HTTP::Response->new( 200, 'OK' );
    $response1->content('row 1 bytes');
    my $ua1  = Fake::UA->new( responses => [$response1] );
    my $row1 = { id => 10, chat_id => 111, message_id => 1, file_id => 'row1', sender => 'ada', media_kind => 'document', caption_note => '' };

    my ( $err1, $ok1 ) = capture_stderr( sub {
        return D2TG::Download::retry_failed_download( $telegram1, $store, $row1, $dir, ua => $ua1 );
    } );

    ok( $ok1, 'first queued row: retry_failed_download does not die despite its own record_message failure' );
    is_deeply( [ grep { $_->[0] eq 'remove_failed_download' } @{ $store->{calls} } ], [],
        'first row: remove_failed_download not attempted, its queue row survives - same guarantee as the earlier block' );

    my $telegram2 = Fake::DownloadTelegram->new( file_path => 'documents/row2.pdf' );
    my $response2 = HTTP::Response->new( 200, 'OK' );
    $response2->content('row 2 bytes');
    my $ua2  = Fake::UA->new( responses => [$response2] );
    my $row2 = { id => 11, chat_id => 222, message_id => 2, file_id => 'row2', sender => 'bob', media_kind => 'document', caption_note => '' };

    my ( $err2, $ok2, $result2 ) = capture_stderr( sub {
        return D2TG::Download::retry_failed_download( $telegram2, $store, $row2, $dir, ua => $ua2 );
    } );

    ok( $ok2, 'second queued row succeeds independently on the SAME store instance - per-row isolation genuinely preserved' );
    like( $result2, qr/\.pdf$/, 'second row returns its own local path, unaffected by the first row\'s store-write failure' );
    is( $err2, '', 'second row logs nothing to STDERR - its own record_message and remove_failed_download both succeed on the shared store' );
    ok( ( grep { $_->[0] eq 'remove_failed_download' && $_->[1] == 11 } @{ $store->{calls} } ),
        'second row: remove_failed_download IS attempted (row id 11) and succeeds, proving the shared store genuinely recovered for a different message_id' );
}

done_testing();
