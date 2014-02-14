#!/usr/bin/env perl

use autodie;
use strict;
use warnings;

use Data::Dumper;
use JSON;
use Net::Google::Spreadsheets;
use Path::Class;

use constant AUTH => glob '~/.google.json';

use constant SPREADSHEET => 'Possible CCCC Kids';
use constant ROLE_SHEET  => 'Sheet1';

my @DAY = qw( monday tuesday wednesday thursday friday );

my %DAY = map { $DAY[$_] => $_ + 1 } 0 .. $#DAY;

my $auth = JSON->new->decode( scalar file(AUTH)->slurp );

my $service = Net::Google::Spreadsheets->new(%$auth);

my $sheet = $service->spreadsheet( { title => SPREADSHEET } );
my $work = $sheet->worksheet( { title => ROLE_SHEET } );

my @cohort    = ();
my %applicant = ();
my %places    = ();

for my $kid ( map { $_->content } $work->rows ) {
  #  print JSON->new->pretty->canonical->encode($kid);
  my %rec = %$kid;
  for my $k ( keys %rec ) {
    next unless $k =~ /^schedule(.+)/;
    my $sn = $1;
    if ( $rec{id} eq 'PLACES' ) {
      $places{$sn} = $rec{$k} + 0;
    }
    elsif ( $rec{id} eq 'TOTAL' ) {
    }
    else {
      for my $sl ( mk_slot( $rec{$k} ) ) {
        push @{ $applicant{$sn} }, { rule => $sl, kid => \%rec };
      }
    }
  }
  push @cohort, \%rec;
}

die "No PLACES line found" unless keys %places;

# Populate all the sessions with all the kids that might be eligible for
# them
my @session = ();
for my $day (@DAY) {
  my $dn = $DAY{$day};
  for my $sn ( keys %places ) {
    my @role = ();
    for my $cand ( @{ $applicant{$sn} } ) {
      my $rule = $cand->{rule};
      push @role, $cand
       if $rule->{days} > 0 && $rule->{from}[$dn];
    }
    push @session, { day => $dn, session => $sn, role => \@role };
  }
}

#print JSON->new->pretty->canonical->encode( \@session );

while () {
  # Sort by fullness
  @session = sort {
    ( @{ $a->{role} } / $places{ $a->{session} } )
     <=> ( @{ $b->{role} } / $places{ $b->{session} } )
  } @session;

  my $work = $session[-1];

  # All within quota?
  last if @{ $work->{role} } <= $places{ $work->{session} };

  # Sort by flexibility
  @{ $work->{role} }
   = sort { $a->{rule}{flexibility} <=> $b->{rule}{flexibility} }
   @{ $work->{role} };

  my $app = $work->{role}[-1];

  last if $app->{rule}{flexibility} <= 1;    # no wiggle

  # Remove from day
  pop @{ $work->{role} };
  my $rule = $app->{rule};
  $rule->{from}[$work->{day}] = 0;
  $rule->{flexibility} = count( $rule->{from} ) / $rule->{days};

#  print "Removed $app->{kid}{id} from $work->{day} / $work->{session}\n";
}

report( \@session );

# Now back annotate the kids with which slots they got
for my $sess (@session) {
  my $day = $sess->{day};
  my $sn  = $sess->{session};
  for my $app ( @{ $sess->{role} } ) {
    $app->{kid}{timetable}{$sn}{$day}++;
  }
}

my @sn = sort keys %places;
my @hdr = ( 'id', 'who' );
for my $sn (@sn) {
  push @hdr, "$sn (wanted)", "$sn (available)";
}
my @rep = ( [@hdr] );
for my $kid (@cohort) {
  my $row = [$kid->{id}, $kid->{who}];
  for my $sn (@sn) {
    push @$row, $kid->{"schedule$sn"}, as_days( $kid->{timetable}{$sn} );
  }
  push @rep, $row;
}

my $fmt = format_for( \@rep );
for my $row (@rep) {
  printf "$fmt\n", @$row;
}

#print JSON->new->pretty->canonical->encode( \@cohort );

sub format_for {
  my $rep = shift;
  my @w   = ();
  for my $row (@$rep) {
    for my $i ( 0 .. $#$row ) {
      my $len = length $row->[$i];
      $w[$i] = $len unless defined $w[$i] && $w[$i] > $len;
    }
  }
  return join ' | ', map "%-${_}s", @w;
}

sub as_days {
  my $h = shift;
  return join ', ',
   map { substr $DAY[$_ - 1], 0, 3 } sort { $a <=> $b } keys %$h;
}

sub report {
  my $session = shift;
  my %idx     = ();
  $idx{ $_->{day} }{ $_->{session} } = $_ for @$session;
  for my $dn ( sort { $a <=> $b } keys %idx ) {
    my $day = $idx{$dn};
    for my $sn ( sort keys %$day ) {
      my $sess = $day->{$sn};
      my $role = $sess->{role};
      print $DAY[$dn - 1], '-', $sn, ': ',
       scalar(@$role), ' requested/', $places{$sn}, ' available. These kids wanted this slot [',
       join( ', ', map { $_->{kid}{id} } @$role ), "]\n";
    }
  }
}

sub can_bind {
  my ( $kid, $sn, $day ) = @_;

  if ( my $slot = $kid->{slots}{$sn} ) {
    for my $sl (@$slot) {
      return count( $sl->{from} ) / $sl->{days}
       if $sl->{days} > 0 && $sl->{from}[$day];
    }
  }

  return;
}

sub count {
  my $ar  = shift;
  my $tot = 0;
  for (@$ar) { $tot++ if $_ }
  return $tot;
}

sub mk_slot {
  my @sl = parse_slot(shift);
  $_->{flexibility} = count( $_->{from} ) / $_->{days} for @sl;
  return @sl;
}

sub parse_slot {
  my $v = shift;
  $v =~ s/\s+//g;
  return if $v eq '';
  # Special case a simple number as N days
  return ( { days => $v + 0, from => [0, 1, 1, 1, 1, 1, 0] } )
   if $v =~ /^[1-5]$/;
  return parse_range($v);
  die "Can't parse $v\n";
}

sub parse_range {
  my $v    = shift;
  my @slot = ();
  for my $rr ( split /,/, $v ) {
    my $sl = { days => 0, from => [0, 0, 0, 0, 0, 0, 0] };
    if ( $rr =~ /^([\w\d]+)-([\w\d]+)$/ ) {
      my $from = day_num($1);
      my $to   = day_num($2);
      die "Days in range out of order" unless $from < $to;
      $sl->{days} = $to - $from + 1;
      $sl->{from}[$_] = 1 for $from .. $to;
    }
    elsif ( $rr =~ /^[\w\d]+(?:\/[\w\d]+)*$/ ) {
      my @alt = map { day_num($_) } split /\//, $rr;
      $sl->{days} = 1;
      $sl->{from}[$_] = 1 for @alt;
    }
    else {
      die "Can't parse slot: $rr\n";
    }
    push @slot, $sl;
  }
  return @slot;
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
