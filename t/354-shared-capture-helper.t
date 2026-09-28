#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";

# TGT-353 (found via a scheduled JOB-004 improvement hunt): capture_stdout
# and capture_std were duplicated byte-identically across 31 test files
# (verified via md5sum, not assumed) - the same "found it twice, extract
# it" class TGT-153 (Fake::UA) and TGT-203 (Test::CaptureStdio) already
# applied to this project's own test suite. Extracted into
# Test::Capture, exporting both under their original names so every
# call site's own existing invocation shape is unchanged.

use Test::Capture qw(capture_stdout capture_std);

my $out = capture_stdout( sub { print "hello\n"; warn "should not be captured by capture_stdout\n"; } );
is( $out, "hello\n", 'capture_stdout returns only stdout' );

my ( $out2, $err2 ) = capture_std( sub { print "world\n"; warn "oops\n"; } );
is( $out2, "world\n", 'capture_std returns stdout as its first element' );
like( $err2, qr/oops/, 'capture_std returns stderr as its second element' );

done_testing();
