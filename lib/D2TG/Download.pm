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

        unless ( -e $local_path ) {
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
existing file is kept as-is and nothing is re-written, so identical
content downloaded any number of times only ever occupies one copy of
disk space. Without C<dir>, behavior is unchanged from before this
ticket: a uniquely-named file in the OS temp directory every call, never
deduplicated.

=cut
