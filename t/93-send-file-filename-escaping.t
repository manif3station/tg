use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempfile tempdir);
use File::Spec;
use HTTP::Response;

require D2TG::Telegram;

# TGT-125 (found via a scheduled hourly bug-hunt): D2TG::Telegram::_send_file
# (backing send_photo/send_document, used by cli/send.pl) inserts the
# local file's basename directly into the multipart Content-Disposition
# header's filename="..." attribute with no escaping. A literal double-
# quote in the filename prematurely closes the quoted attribute,
# corrupting that header line - e.g. a file named 'evil".jpg' produces
# 'filename="evil".jpg"', a malformed multipart request.

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

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'evil".jpg' );
    open my $fh, '>', $path or die $!;
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path );

    my $content = $ua->{calls}[0]{req}->content;
    my ($disposition_line) = $content =~ /^(Content-Disposition:.*filename=.*)$/m;

    ok( defined $disposition_line, 'a Content-Disposition line with a filename attribute is present' );

    # A well-formed header has an EVEN number of unescaped double-quotes
    # closing each attribute - the literal quote in the filename must be
    # escaped (\"), not left to prematurely close the attribute.
    like( $disposition_line, qr/filename="evil\\".jpg"/,
        'the double-quote inside the filename is escaped, not left to prematurely close the attribute' );
    unlike( $disposition_line, qr/filename="evil"\.jpg"/,
        'the header is not corrupted into filename="evil" followed by stray .jpg" text' );
}

{
    # A filename with a literal backslash must also survive intact -
    # RFC 2388/6266 escaping conventions require backslashes themselves
    # to be escaped too, so an escaped quote isn't ambiguous with a
    # filename that happens to end in a literal backslash.
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'weird\\name.jpg' );
    open my $fh, '>', $path or die $!;
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path );

    my $content = $ua->{calls}[0]{req}->content;
    like( $content, qr/filename="weird\\\\name\.jpg"/,
        'a literal backslash in the filename is escaped too' );
}

{
    # Codex review finding (high severity): a filename can legally
    # contain a literal CR/LF on Unix - left unstripped, that would
    # inject an ADDITIONAL raw header line into the multipart request
    # regardless of the quote/backslash escaping above, since CR/LF is
    # what actually terminates a header line here. This must never
    # result in an injected header reaching the request at all.
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, "evil\r\nX-Injected: 1.jpg" );
    open my $fh, '>', $path or die $!;
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path );

    my $content = $ua->{calls}[0]{req}->content;
    # The CR/LF itself must never survive to actually terminate a
    # header line - it's fine for the literal text "X-Injected" to
    # still appear as harmless text inside the filename attribute
    # (nothing dangerous about the substring on its own); what matters
    # is that it can never become a REAL header line (i.e. never
    # preceded by an actual \r\n at the start of a line).
    unlike( $content, qr/\r\nX-Injected:/, 'the CR/LF never survives to actually start a new (injected) header line' );
    like( $content, qr/filename="evilX-Injected: 1\.jpg"/,
        'the CR/LF is stripped and the rest of the filename is preserved as harmless inline text, not an injected header' );
}

# Regression: a completely ordinary filename must be totally unaffected.
{
    my ( $fh, $path ) = tempfile( SUFFIX => '.jpg' );
    print {$fh} 'fake jpeg bytes';
    close $fh;

    my $ua = Fake::UA->new(
        responses => [ http_response( content => '{"ok":true,"result":{"message_id":5}}' ) ],
    );
    my $tg = D2TG::Telegram->new( token => 'test-token', ua => $ua );

    $tg->send_photo( 42, $path );

    my ( undef, undef, $basename ) = File::Spec->splitpath($path);
    like( $ua->{calls}[0]{req}->content, qr/filename="\Q$basename\E"/,
        'an ordinary filename with no special characters is completely unaffected' );
}

done_testing();
