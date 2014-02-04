#!/usr/bin/env perl

use strict;
use warnings;

use JSON;

my @hdr = ();

my @db = ();
while (<>) {
  chomp;
  my @f = split /\t/;
  next unless @f;
  unless (@hdr) {
    @hdr = @f;
    next;
  }
  my $rec = {};
  @{$rec}{@hdr} = @f;
  push @db, $rec;
}

print JSON->new->pretty->canonical->encode( \@db );

# vim:ts=2:sw=2:sts=2:et:ft=perl

