package Fake::HttpResponse;

use strict;
use warnings;
use Exporter qw(import);
use HTTP::Response;

our @EXPORT_OK = qw(http_response);

# TGT-358 (found via a scheduled JOB-004 improvement hunt): http_response
# was duplicated byte-identically across 7 test files (verified via
# md5sum, not assumed) - the same "found it twice, extract it" class
# TGT-153/203/353/355 already applied to this project's own test suite.

sub http_response {
    my (%args) = @_;
    my $res = HTTP::Response->new( $args{code} // 200, $args{message} // 'OK' );
    $res->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $res->content( $args{content} ) if defined $args{content};
    return $res;
}

1;

=head1 NAME

Fake::HttpResponse - shared test helper for building a fake Telegram API HTTP::Response

=head1 SYNOPSIS

    use Fake::HttpResponse qw(http_response);

    my $res = http_response( code => 200, content => '{"ok":true}' );
    my $ua  = Fake::UA->new( response => $res );

=head1 DESCRIPTION

TGT-358 (found via a scheduled JOB-004 improvement hunt): C<http_response>
was duplicated across many test files exercising L<D2TG::Telegram>'s
outbound HTTP calls (paired with L<Fake::UA>) - each building a plain
C<HTTP::Response> with the JSON content-type Telegram's real API always
sends.

=head1 FUNCTIONS

=head2 http_response(code => $code, message => $message, content => $content)

Returns an C<HTTP::Response> with C<Content-Type: application/json;
charset=utf-8> already set. C<code> defaults to C<200>, C<message>
defaults to C<'OK'>, C<content> is unset (empty body) unless given.

=cut
