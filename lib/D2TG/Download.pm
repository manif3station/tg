package D2TG::Download;

use strict;
use warnings;
use HTTP::Tiny;
use File::Temp qw(tempfile);

sub download_file {
    my ( $telegram, $file_id, %args ) = @_;

    my $file_path = $telegram->get_file($file_id);
    die "D2TG::Download::download_file: no file_path returned for $file_id\n"
      unless defined $file_path;

    my $ua  = $args{ua} || HTTP::Tiny->new;
    my $url = $telegram->file_download_url($file_path);

    my $res = $ua->get($url);
    die "D2TG::Download::download_file: HTTP request failed (status $res->{status} $res->{reason})\n"
      unless $res->{success};

    my $suffix = $file_path =~ /(\.[A-Za-z0-9]+)$/ ? $1 : '';
    my ( $fh, $local_path ) = tempfile( SUFFIX => $suffix, UNLINK => 0 );
    binmode $fh;
    print {$fh} $res->{content};
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
object's C<get_file>, then downloads it via C<file_download_url> to a
local temp file, preserving the original file extension.

=head1 FUNCTIONS

=head2 download_file($telegram, $file_id, ua => $optional_client)

Returns the local path to the downloaded file. Dies if C<get_file>
returns no C<file_path>, or if the download request fails. C<ua> is
optional and defaults to L<HTTP::Tiny>; tests inject a fake here
instead.

=cut
