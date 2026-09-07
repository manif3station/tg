package D2TG::Telegram;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);

sub new {
    my ( $class, %args ) = @_;

    my $token = $args{token} or die "D2TG::Telegram->new requires a token\n";

    return bless {
        token => $token,
        api   => "https://api.telegram.org/bot$token",
        ua    => $args{ua} || HTTP::Tiny->new,
    }, $class;
}

sub _call {
    my ( $self, $method, $params ) = @_;

    my $res = $self->{ua}->post(
        "$self->{api}/$method",
        {
            headers => { 'Content-Type' => 'application/json' },
            content => encode_json( $params || {} ),
        }
    );

    die "D2TG::Telegram $method: HTTP request failed\n" unless $res->{success};

    my $data = decode_json( $res->{content} );

    die "D2TG::Telegram $method failed: "
      . ( $data->{description} || 'unknown error' ) . "\n"
      unless $data->{ok};

    return $data->{result};
}

sub get_me {
    my ($self) = @_;
    return $self->_call( 'getMe', {} );
}

sub get_updates {
    my ( $self, %args ) = @_;

    my $params = { timeout => $args{timeout} // 30 };
    $params->{offset} = $args{offset} if defined $args{offset};

    my $updates = $self->_call( 'getUpdates', $params );

    my $next_offset = $args{offset};
    for my $update (@$updates) {
        my $candidate = $update->{update_id} + 1;
        $next_offset = $candidate
          if !defined $next_offset || $candidate > $next_offset;
    }

    return ( $updates, $next_offset );
}

sub get_file {
    my ( $self, $file_id ) = @_;

    my $result = $self->_call( 'getFile', { file_id => $file_id } );
    return $result->{file_path};
}

1;

=head1 NAME

D2TG::Telegram - minimal Telegram Bot API client

=head1 SYNOPSIS

    my $tg = D2TG::Telegram->new( token => $token );
    my $me = $tg->get_me;
    my ( $updates, $next_offset ) = $tg->get_updates( offset => $offset );
    my $file_path = $tg->get_file($file_id);

=head1 DESCRIPTION

Raw HTTP client against the Telegram Bot API - no SDK dependency, matching
the C<~/skills/tg> blueprint's own "no heavy SDK" principle. Uses
L<HTTP::Tiny> by default; pass C<ua> to the constructor to inject a
different (or mock) client for testing.

=head1 METHODS

=head2 new(token => $token, ua => $optional_client)

=head2 get_me

Returns the bot's own user info.

=head2 get_updates(offset => $offset, timeout => $timeout)

Long-polls C<getUpdates>. Returns a two-element list: the array of update
hashes, and the offset to pass on the next call (one past the highest
C<update_id> seen, or the offset that was passed in if no updates arrived).

=head2 get_file($file_id)

Returns the C<file_path> for a given C<file_id>, for use with Telegram's
file-download endpoint.

=cut
