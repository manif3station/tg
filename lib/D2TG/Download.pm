package D2TG::Download;

use strict;
use warnings;
use LWP::UserAgent;
use File::Temp qw(tempfile);
use File::Spec;
use Digest::SHA qw(sha256_hex);

sub download_file {
    my ( $telegram, $file_id, %args ) = @_;

    my $file_path = $telegram->get_file($file_id);
    die "D2TG::Download::download_file: no file_path returned for $file_id\n"
      unless defined $file_path;

    my $ua  = $args{ua} || LWP::UserAgent->new;
    my $url = $telegram->file_download_url($file_path);

    my $res = $ua->get($url);
    die "D2TG::Download::download_file: HTTP request failed (status @{[ $res->code ]} @{[ $res->message ]})\n"
      unless $res->is_success;

    my $content = $res->decoded_content( charset => 'none' );
    my $suffix  = $file_path =~ /(\.[A-Za-z0-9]+)$/ ? $1 : '';

    if ( defined $args{dir} ) {
        my $hash       = sha256_hex($content);
        my $local_path = File::Spec->catfile( $args{dir}, "$hash$suffix" );

        if ( -e $local_path ) {
            my $now = time();
            utime $now, $now, $local_path;
        }
        else {
            open my $fh, '>:raw', $local_path
              or die "D2TG::Download::download_file: cannot write $local_path: $!\n";
            print {$fh} $content;
            close $fh;
        }

        return $local_path;
    }

    my ( $fh, $local_path ) = tempfile( SUFFIX => $suffix, UNLINK => 0 );
    binmode $fh;
    print {$fh} $content;
    close $fh;

    return $local_path;
}

sub prune_vault {
    my ( $dir, %args ) = @_;
    my $max_bytes = $args{max_bytes} // 100 * 1024 * 1024;

    opendir my $dh, $dir or return;
    my @files = grep { -f "$dir/$_" } readdir $dh;
    closedir $dh;

    my @entries = map {
        my $path = File::Spec->catfile( $dir, $_ );
        my @stat = stat $path;
        { path => $path, size => $stat[7], mtime => $stat[9] };
    } @files;

    my $total = 0;
    $total += $_->{size} for @entries;

    return if $total <= $max_bytes;

    for my $entry ( sort { $a->{mtime} <=> $b->{mtime} } @entries ) {
        last if $total <= $max_bytes;
        unlink $entry->{path} and $total -= $entry->{size};
    }

    return;
}

1;

=head1 NAME

D2TG::Download - download a Telegram-hosted file to a local temp file

=head1 SYNOPSIS

    my $local_path = D2TG::Download::download_file( $telegram, $file_id );

=head1 DESCRIPTION

Resolves C<$file_id> to a C<file_path> via the given L<D2TG::Telegram>
object's C<get_file>, then downloads it via C<file_download_url>,
preserving the original file extension.

=head1 FUNCTIONS

=head2 download_file($telegram, $file_id, ua => $optional_client, dir => $optional_dir)

Returns the local path to the downloaded file. Dies if C<get_file>
returns no C<file_path>, or if the download request fails. C<ua> is
optional and defaults to L<LWP::UserAgent> (TGT-028); tests inject a
fake here instead.

C<dir> (TGT-051, typically C<D2TG::Config::attachments_dir>'s result) is
optional. When given, the file is named by its own content's SHA256
hash (plus the original extension) and written under C<dir> - if a file
with that exact hash already exists there, the download's HTTP request
still happens (the content has to be fetched to know its hash) but the
existing file's content is kept as-is and nothing is re-written, so
identical content downloaded any number of times only ever occupies one
copy of disk space. Its mtime, however, IS refreshed to now on every
such dedup hit (TGT-054) - a repeatedly re-sent file counts as freshly
used, so C<prune_vault>'s oldest-C<mtime>-first eviction (below) treats
it as recently active rather than as stale since its one-time original
download. Without C<dir>, behavior is unchanged from before TGT-051: a
uniquely-named file in the OS temp directory every call, never
deduplicated.

=head2 prune_vault($dir, max_bytes => $bytes = 100MB)

Keeps the attachment vault (TGT-052, typically
C<D2TG::Config::attachments_dir>'s result) at or under C<max_bytes>
total: if the sum of every regular file's size in C<$dir> exceeds it,
deletes files oldest-C<mtime>-first until back at or under the cap.
A vault already at or under the cap is left completely untouched - not
even a listing beyond the size check. A non-existent or unreadable
C<$dir> is a silent no-op (nothing to prune). Since content-addressed
files (see C<download_file> above) are named by their own hash, deleting
an old copy here can never orphan a still-referenced summary pointing
at a different file - the same content, if downloaded again later,
simply gets re-fetched and re-written under its same hash-derived name.

=cut
