#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";

# TGT-358 (found via a scheduled JOB-004 improvement hunt): http_response
# was duplicated byte-identically across 7 test files (verified via
# md5sum, not assumed) - the same "found it twice, extract it" class
# TGT-153/203/353/355 already applied to this project's own test suite.

use Fake::HttpResponse qw(http_response);

{
    my $res = http_response();
    is( $res->code, 200, 'default code is 200' );
    is( $res->message, 'OK', 'default message is OK' );
    is( $res->header('Content-Type'), 'application/json; charset=utf-8', 'default Content-Type is set' );
}

{
    my $res = http_response( code => 404, message => 'Not Found', content => '{"error":true}' );
    is( $res->code, 404, 'custom code is honored' );
    is( $res->message, 'Not Found', 'custom message is honored' );
    is( $res->content, '{"error":true}', 'custom content is honored' );
}

done_testing();
