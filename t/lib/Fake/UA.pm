package Fake::UA;

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    return bless { responses => $args{responses} || [], calls => [] }, $class;
}

sub request {
    my ( $self, $req ) = @_;
    push @{ $self->{calls} }, { url => $req->uri->as_string, req => $req };
    return shift @{ $self->{responses} };
}

1;

=head1 NAME

Fake::UA - shared test double for an LWP::UserAgent-shaped request() client

=head1 SYNOPSIS

    use Fake::UA;

    my $ua = Fake::UA->new( responses => [ $http_response_1, $http_response_2 ] );
    my $client = D2TG::Telegram->new( token => 'test-token', ua => $ua );
    $client->get_updates( offset => 1 );

    is( $ua->{calls}[0]{url}, '...', 'the expected endpoint was called' );
    is( $ua->{calls}[0]{req}->content, '...', 'the expected body was sent' );

=head1 DESCRIPTION

TGT-153 (JOB-004 scheduled improvement hunt): C<request()>-shaped C<Fake::UA>
was independently defined across several test files exercising
L<D2TG::Telegram>'s outbound HTTP calls - C<md5sum> identified two
exact-duplicate clusters before extraction (not assumed), and the
remaining difference between those two clusters was inspected by hand.
Three of the five original inline copies carried an extra, entirely
unused C<method =E<gt> 'request'> key inside each recorded call - grepped
every affected file first to confirm nothing asserts on it before
dropping it here, so this shared version changes no test's observable
behavior. A third, superficially same-named
C<Fake::UA> found during the same hunt (C<t/48-dedup-refreshes-mtime.t>,
C<t/83-failed-download-queue.t>) turned out to be a genuinely different
shape - a C<get()>-only fake with no C<request()> method and no call
tracking - and was deliberately left out of this extraction rather than
forced to fit.

Every C<responses> entry is consumed in order, one per C<request()> call;
C<calls> accumulates C<{ url =E<gt> ..., req =E<gt> ... }> for each call made,
in call order, for assertions against.

=cut
