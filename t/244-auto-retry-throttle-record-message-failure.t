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

# TGT-244 (found via a scheduled JOB-003 hourly bug hunt): TGT-221's own
# auto-retry throttle (AUTO_RETRY_INTERVAL_SECONDS, 60s) is silently
# bypassed for a row whose download succeeds but whose record_message
# bookkeeping write keeps failing - exactly the "persistently-failing
# record_message" scenario TGT-196 already documented as real.
#
# retry_failed_download always returns (1, $local_path) once the download
# itself succeeds, regardless of whether record_message succeeded -
# auto_retry_failed_downloads only stamps last_retry_at (via
# D2TG::Store::mark_failed_download_retried) when that return is FALSE.
# So a row stuck in this exact partial-success state never gets
# last_retry_at stamped, and D2TG::Store::failed_downloads_due_for_retry's
# "last_retry_at IS NULL" clause keeps matching it on every single poll
# cycle instead of once per 60s.

package Store::RecordMessageAlwaysFails;

our @ISA = ('D2TG::Store');

sub record_message {
    die "simulated persistent record_message failure (e.g. database busy)\n";
}

package Fake::DownloadTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path} }, $class;
}

sub get_file           { my ( $self, $file_id )  = @_; return $self->{file_path}; }
sub file_download_url  { my ( $self, $file_path ) = @_; return "https://api.telegram.org/file/bottest-token/$file_path"; }

package Fake::UA;

sub new { my ( $class, %args ) = @_; return bless { responses => $args{responses} || [] }, $class; }
sub get { my ($self) = @_; return shift @{ $self->{responses} }; }

package main;

my $dir = tempdir( CLEANUP => 1 );
my $store = Store::RecordMessageAlwaysFails->new(
    db_path       => File::Spec->catfile( $dir, 'store.sqlite' ),
    admin_chat_id => 1,
);

my $id = $store->record_failed_download(
    999, 77, 'AABBstuck', sender => 'ada', media_kind => 'document', caption_note => '', error => 'e',
);

my $telegram = Fake::DownloadTelegram->new( file_path => 'documents/file_stuck.pdf' );
my $response = HTTP::Response->new( 200, 'OK' );
$response->content('bytes that download fine');
my $ua = Fake::UA->new( responses => [$response] );

# First automatic-retry pass: the download itself succeeds, but
# record_message dies every time, so the row is deliberately kept
# queued (with local_path persisted via mark_failed_download_downloaded,
# per TGT-196) rather than removed.
D2TG::Download::auto_retry_failed_downloads( $telegram, $store, $dir, ua => $ua );

my ($row) = @{ $store->failed_downloads };
ok( $row, 'the row is still queued after a retry whose download succeeded but whose record_message kept failing' );
ok( $row->{local_path}, 'the successfully-downloaded local_path was persisted so a future retry will not re-download' );

# The actual bug under test: immediately re-checking what's due for
# auto-retry (i.e. the very next poll cycle, well under 60 seconds
# later) must NOT include this row again - the 60s throttle must still
# apply even though the failure was in record_message, not in the
# download step itself.
my @due = @{ $store->failed_downloads_due_for_retry };
is( scalar @due, 0,
    'a row whose download succeeded but whose record_message kept failing is NOT re-attempted on the very next poll cycle (60s throttle must still apply)'
) or diag(
    "BUG TGT-244: retry_failed_download returns (1, \$local_path) whenever the download itself "
  . "succeeds, even though record_message failed and the row is still queued - "
  . "auto_retry_failed_downloads only stamps last_retry_at when that return is false, so "
  . "last_retry_at is never set here and the row is treated as always due, defeating the "
  . "documented 60s AUTO_RETRY_INTERVAL_SECONDS throttle."
);

ok( $row->{last_retry_at} || !@due,
    'last_retry_at should be stamped (or the row otherwise correctly excluded) after a retry attempt that left the row queued' );

# Once the interval has genuinely elapsed, the row must become due
# again - the fix must not simply stop retrying it forever.
$store->{dbh}->do(
    q{UPDATE failed_downloads SET last_retry_at = datetime('now', '-61 seconds') WHERE id = ?}, undef, $id,
);
@due = @{ $store->failed_downloads_due_for_retry };
is( scalar @due, 1, 'the row becomes due again once the 60s interval has genuinely elapsed' );

done_testing();
