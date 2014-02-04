#!/usr/bin/env perl

use autodie;
use strict;
use warnings;

use Data::Dumper;
use JSON;
use Net::Google::Spreadsheets;
use Path::Class;

use constant AUTH => glob '~/.google.json';

my @DAY = qw( monday tuesday wednesday thursday friday );

my %DAY = map { $DAY[$_] => $_ + 1 } 0 .. $#DAY;

my $auth = JSON->new->decode( scalar file(AUTH)->slurp );

my $service = Net::Google::Spreadsheets->new(%$auth);

my $sheet = $service->spreadsheet( { title => 'Possible CCCC Kids' } );
my $work   = $sheet->worksheet( { title => 'Sheet1' } );
my @cohort = ();
my %places = ();
for my $kid ( map { $_->content } $work->rows ) {
  my %rec = %$kid;
  for my $k ( keys %rec ) {
    next unless $k =~ /^schedule(.+)/;
    my $sn = $1;
    if ( $rec{id} eq 'PLACES' ) {
      $places{$sn} = $rec{$k};
    }
    elsif ( $rec{id} eq 'TOTAL' ) {
    }
    else {
      $rec{$k} = make_srec( $rec{$k} );
    }
  }
  push @cohort, \%rec;
}

# Build sessions
my @session = ();
for my $day (@DAY) {
  for my $sn ( sort keys %places ) {
    push @session,
     {name     => "$day-$sn",
      alloc    => [],
      day      => $DAY{$day},
      places   => $places{$sn},
      key      => "schedule$sn",
      complete => 0,
     };
  }
}

print JSON->new->pretty->canonical->encode( \@cohort );

while () {

  @session = sort {
    $a->{complete} <=> $b->{complete}
     || @{ $a->{alloc} } / $a->{places} <=> @{ $b->{alloc} } / $b->{places}
  } @session;

  my $sess = $session[0];    # least filled
  last if $sess->{complete};                        # can't continue
  last if @{ $sess->{alloc} } = $sess->{places};    # all full

  my $key = $sess->{key};
  my $day = $sess->{day};

  my $kid = get_kid( $key, $day, @cohort );
  if ($kid) {
    print "Allocating $kid->{who} to $sess->{name}\n";
    push @{ $sess->{alloc} }, $kid;
  }
  else {
    print "No more candidates for $sess->{name}\n";
    $sess->{complete} = 1;
  }
}

sub get_kid {
  my ( $key, $day, @cohort ) = @_;

  for my $kid (@cohort) {
    my $srec = $kid->{$key};
    if ( 'ARRAY' eq $srec->{slot} ) {
      if ( $srec->{slot}{$day} ) {
        $srec->{slot}{$day} = 0;
        $srec->{got}++;
        return $kid;
      }
    }
    else {
      if ( $srec->{slot} > 0 ) {
        $srec->{slot}--;
        $srec->{got}++;
        return $kid;
      }
    }
  }

  return;
}

sub make_srec {
  my $v    = shift;
  my $slot = parse_slot($v);
  return {
    want        => want($slot),
    got         => 0,
    slot        => $slot,
    flexibility => 'ARRAY' eq ref $slot ? 0 : 1,
  };
}

sub want {
  my $slot = shift;
  return $slot unless 'ARRAY' eq ref $slot;
  my $tot = 0;
  for (@$slot) { $tot++ if $_ }
  return $tot;
}

sub parse_slot {
  my $v = shift;
  $v =~ s/\s+//g;
  return 0 if $v eq '';
  return $v + 0 if $v =~ /^[1-5]$/;
  return parse_range($v);
  die "Can't parse $v\n";
}

sub parse_range {
  my $v = shift;
  my $slot = [0, 0, 0, 0, 0, 0, 0];
  for my $rr ( split /,/, $v ) {
    if ( $rr =~ /^([\w\d]+)-([\w\d]+)$/ ) {
      $slot->[$_] = 1 for ( day_num($1) .. day_num($2) );
    }
    elsif ( $rr =~ /^([\w\d]+)$/ ) {
      $slot->[day_num($1)] = 1;
    }
    else {
      die "Can't parse slot: $rr\n";
    }
  }
  return $slot;
}

sub day_num {
  my $day = lc shift;
  return $day if $day =~ /^\d+$/;
  die "Bad day: $day\n" unless $day =~ /^\w+$/;
  my $like = qr{^$day};
  my @hit = grep { $_ =~ $like } keys %DAY;
  die "Unknown day: $day" unless @hit;
  die "Ambiguous day: $day" if @hit > 1;
  return $DAY{ $hit[0] };
}

# vim:ts=2:sw=2:sts=2:et:ft=perl
