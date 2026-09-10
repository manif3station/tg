use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempfile);
use HTTP::Response;

# TGT-162 (found via a scheduled hourly bug-hunt): D2TG::Telegram::_send_file
# splices $opts{caption} into the raw multipart body with zero
# sanitization, unlike the adjacent filename field which was hardened for
# TGT-125. If a caption happens to contain the exact multipart boundary
# string this call generated, it can prematurely terminate the body,
# letting trailing bytes be reinterpreted as new form fields.
#
# $boundary is 'D2TGBoundary' . int(rand(1e9)) . time - both rand and time
# are overridden below (via CORE::GLOBAL, set up in a BEGIN block before
# D2TG::Telegram is compiled) so the exact boundary value is known and a
# colliding caption can be crafted deterministically.

BEGIN {
    *CORE::GLOBAL::rand = sub (;$) { return 123456789 };
    *CORE::GLOBAL::time = sub ()  { return 1700000000 };
}

require D2TG::Telegram;

package Fake::UA;

sub new {
    my ( $class, %args ) = @_;
    return bless { responses => $args{responses} || [], calls => [] }, $class;
}

sub request {
    my ( $self, $req ) = @_;
    push @{ $self->{calls} }, { req => $req };
    return shift @{ $self->{responses} };
}

package main;

sub http_response {
    my (%args) = @_;
    my $res = HTTP::Response->new( $args{code} // 200, $args{message} // 'OK' );
    $res->header( 'Content-Type' => 'application/json; charset=utf-8' );
    $res->content( $args{content} ) if defined $args{content};
    return $res;
}

my $known_boundary = 'D2TGBoundary' . int( rand(1e9) ) . time;

{
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $colliding_caption = "hello $known_boundary world";
    $tg->send_photo( 42, $path, caption => $colliding_caption );

    my $content = $ua->{calls}[0]{req}->content;

    unlike( $content, qr/hello \Q$known_boundary\E world/,
        'the boundary substring is stripped out of the caption text itself, not left intact inside body content' );

    like( $content, qr/name="caption"\r\n\r\nhello  world\r\n/,
        'the rest of the caption text survives, with the boundary substring simply removed' );

    # Structural sanity: exactly one opening boundary line per real part,
    # plus the final closing boundary - a still-parseable multipart body.
    my @real_boundaries = ( $content =~ /^--\Q$known_boundary\E\r?$/mg );
    is( scalar(@real_boundaries), 3, 'exactly 3 real part boundaries remain (chat_id, caption, photo) - none injected by the caption' );
}

{
    # Multiple occurrences of the boundary string in one caption must
    # all be stripped, not just the first.
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path, caption => "$known_boundary twice: $known_boundary" );

    my $content = $ua->{calls}[0]{req}->content;
    unlike( $content, qr/\Q$known_boundary\E twice/,
        'every occurrence of the boundary string is stripped, not just the first' );
    like( $content, qr/name="caption"\r\n\r\n twice: \r\n/,
        'both occurrences are removed, leaving the surrounding text intact' );
}

{
    # A caption embedding the boundary in real delimiter syntax
    # (preceded by \r\n--, exactly how a genuine part separator looks)
    # must still be neutralized, not merely the bare value.
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path, caption => "abc\r\n--$known_boundary\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n999" );

    my $content = $ua->{calls}[0]{req}->content;
    my @real_boundaries = ( $content =~ /^--\Q$known_boundary\E\r?$/mg );
    is( scalar(@real_boundaries), 3,
        'a delimiter-shaped injection attempt does not create an extra real boundary - still exactly 3 (chat_id, caption, photo), so it can never be parsed as a genuine new part regardless of what inert text remains inside the caption body' );
}

{
    # Ordinary quotes, backslashes, and CR/LF in a caption are body
    # content, not header syntax here - they must survive completely
    # untouched, unlike filename's own escaping of the same characters.
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    my $caption = qq{a "quoted" caption with a \\backslash\\ and\r\na real line break};
    $tg->send_photo( 42, $path, caption => $caption );

    my $content = $ua->{calls}[0]{req}->content;
    like( $content, qr/\Q$caption\E/,
        'quotes, backslashes, and CR/LF in the caption survive completely untouched - they are body content, not header syntax' );
}

{
    # Regression: an ordinary caption with no boundary collision is
    # completely unaffected.
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path, caption => 'an ordinary caption' );

    my $content = $ua->{calls}[0]{req}->content;
    like( $content, qr/name="caption"\r\n\r\nan ordinary caption\r\n/,
        'an ordinary caption with no boundary collision is sent unchanged, byte-for-byte' );
}

done_testing();
