#!/usr/bin/perl
#
# Module: vyatta-show-vrrp.pl
# 
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2005, 2006, 2007 Vyatta, Inc.
# All Rights Reserved.
# 
# Author: Stig Thormodsrud
# Date: October 2007
# Description: display vrrp info
# 
# **** End License ****
# 
use lib "/opt/vyatta/share/perl5/";
use Vyatta::Keepalived;
use Vyatta::Interface;

use strict;
use warnings;


sub elapse_time {
    my ($start, $stop) = @_;

    my $seconds   = $stop - $start;
    my $string    = '';
    my $secs_min  = 60;
    my $secs_hour = $secs_min  * 60;
    my $secs_day  = $secs_hour * 24;
    my $secs_week = $secs_day  * 7;
    
    my $weeks = int($seconds / $secs_week);
    if ($weeks > 0 ) {
	$seconds = int($seconds % $secs_week);
	$string .= $weeks . "w";
    }
    my $days = int($seconds / $secs_day);
    if ($days > 0) {
	$seconds = int($seconds % $secs_day);
	$string .= $days . "d";
    }
    my $hours = int($seconds / $secs_hour);
    if ($hours > 0) {
	$seconds = int($seconds % $secs_hour);
	$string .= $hours . "h";
    }
    my $mins = int($seconds / $secs_min);
    if ($mins > 0) {
	$seconds = int($seconds % $secs_min);
	$string .= $mins . "m";
    }
    $string .= $seconds . "s";

    return $string;
}

sub get_state_link {
    my $intf_name = shift;

    my $intf = new Vyatta::Interface($intf_name);
    die "Unknown interface [$intf_name]" unless $intf;
    
    my ($state, $link);
    if ($intf->up()) {
	$state = 'up';
    } else {
	$state = 'admin down';
    }

    if ($intf->carrier() == 1) {
        $link = 'up';
    } else {
        $link = 'down';
    }
    return ($state, $link);
}

sub parse_arping {
    my $file = shift;
    
    return "" if ! -f $file;

    open (my $FD, '<', $file)
	or die "Can't open file $file";

    my @lines = <$FD>;
    close $FD;
    my $mac = undef;
    foreach my $line (@lines) {
	# regex for xx:xx:xx:xx:xx:xx
	if ($line =~ /(([0-9A-Fa-f]{1,2}:){5}[0-9A-Fa-f]{1,2})/) {
	    $mac = $1;
	    return uc($mac);
	}
    }
    return $mac;
}

sub get_master_info {
    my ($intf, $group, $vip) = @_;

    # remove mask if vip has one
    if ($vip =~ /([\d.]+)\/\d+/) {
	$vip = $1;
    }

    # Calling snoop_for_master() is an expensive operation, so we 
    # normally only do it on vrrp state transitions by calling the
    # vyatta-vrrp-state.pl script.  However if there are more than
    # 2 routers in the vrrp group when a transition occurs, then 
    # only those 2 routes that transitioned will know who the current
    # master is and it's priority.  So here we will arp for the VIP
    # address and compare it to our masterfile.  If it doesn't match
    # then we will snoop for the new master.

    my $master_file = Vyatta::Keepalived::get_master_file($intf, $group);
    my $arp_file    = "$master_file.arp";
    my $source_ip   = (vrrp_get_config($intf, $group))[0];

    my $interface = new Vyatta::Interface($intf);
    my $arp_intf = $intf;
    if ($interface->vif()) {
	$arp_intf = $interface->physicalDevice();
    }
    my $cmd = "/usr/bin/arping -c1 -f -I $arp_intf -s $source_ip $vip";
    system("$cmd > $arp_file");
    my $arp_mac = parse_arping($arp_file);

    if ( ! -f $master_file) {
	Vyatta::Keepalived::snoop_for_master($intf, $group, $vip, 2);
    }

    if ( -f $master_file) {
	my $master_ip  = `grep ip.src $master_file 2> /dev/null`;
	my $master_mac = `grep eth.src $master_file 2> /dev/null`;
	chomp $master_ip; chomp $master_mac;

	# regex for show="xx:xx:xx:xx:xx:xx	
	if (defined $master_mac and 
	    $master_mac =~ /show=\"(([0-9A-Fa-f]{1,2}:){5}[0-9A-Fa-f]{1,2})/) 
	{
	    $master_mac = uc($1);
	    if (defined($arp_mac) and ($arp_mac ne $master_mac)) {
		Vyatta::Keepalived::snoop_for_master($intf, $group, $vip, 2);
		$master_ip = `grep ip.src $master_file 2> /dev/null`;
	    }
	} 

	if (defined $master_ip and 
	    $master_ip =~ m/show=\"(\d+\.\d+\.\d+\.\d+)\"/) 
	{
	    $master_ip = $1;
	} else {
	    $master_ip = "unknown";
	    system("mv $master_file /tmp");
	}

	my $priority = `grep vrrp.prio $master_file 2> /dev/null`;
	chomp $priority;
	if (defined $priority and $priority =~ m/show=\"(\d+)\"/) {
	    $priority = $1;
	} else {
	    $priority = "unknown";
	}

	return ($master_ip, $priority, $master_mac);
    } else {
	return ('unknown', 'unknown', '');
    }
}

sub vrrp_showsummary {
    my ($file) = @_;
    my $owner = "no";
    my ($start_time, $intf, $group, $state, $ltime) =
        Vyatta::Keepalived::vrrp_state_parse($file);
    my ($interface_state, $link) = get_state_link($intf);
    if ($state eq "master" || $state eq "backup" || $state eq "fault") {
        my ($primary_addr, $priority, $preempt, $advert_int, $auth_type,
	    $vmac_interface,
            @vips) = Vyatta::Keepalived::vrrp_get_config($intf, $group);
	my $format = "\n%-16s%-8s%-8s%-16s%-10s%-9s%-13s";
	my $vip = shift @vips;
	if ($vmac_interface) {
	    $intf = "$intf" . "v" . "$group";
            $owner = "yes" if ($priority == 255); 
	}
	printf($format, $intf, $group, 'vip', $vip, $link, $owner, $state);
        foreach my $vip (@vips){
	    printf("\n%-24s%-8s%-16s", ' ', 'vip', $vip);
        }
    } else {
        print "Physical interface $intf, State: unknown\n";
    }
}

sub vrrp_show {
    my ($file) = @_;
    my $owner = "no";
    my $now_time = time;
    my ($start_time, $intf, $group, $state, $ltime) = 
	Vyatta::Keepalived::vrrp_state_parse($file);
    my ($interface_state, $link) = get_state_link($intf);
    my $first_vip = '';
    if ($state eq "master" || $state eq "backup" || $state eq "fault") {
	my ($primary_addr, $priority, $preempt, $advert_int, $auth_type, 
	    $vmac_interface,
	    @vips) = Vyatta::Keepalived::vrrp_get_config($intf, $group);
        my $sync = list_vrrp_sync_group($intf, $group);
	print "Physical interface: $intf, Source Address $primary_addr\n";
	if ($vmac_interface) {
	    my $vma = "$intf" . "v" . "$group";
            $owner = "yes" if ($priority == 255);
	    print "  Virtual MAC interface: $vma\n";
            print "  Address Owner: $owner\n";
	}
	print "  Interface state: $link, Group $group, State: $state\n";
	print "  Priority: $priority, Advertisement interval: $advert_int, ";
	print "Authentication type: $auth_type\n";
	my $vip_count = scalar(@vips);
	my $string = "  Preempt: $preempt, VIP count: $vip_count, VIP: ";
	my $strlen = length($string);
	print $string;
	foreach my $vip (@vips) {
	    if ($first_vip eq '') {
		$first_vip = $vip;
	    }
	    if ($vip_count != scalar(@vips)) {
		print " " x $strlen;
	    }
	    print "$vip\n";
	    $vip_count--;
	}
	if ($state eq "master") {
	    print "  Master router: $primary_addr\n";
	} elsif ($state eq "backup") {
	    my ($master_rtr, $master_prio,$master_mac) = 
		get_master_info($intf, $group, $first_vip);
	    print "  Master router: $master_rtr";
	    if ($master_mac ne '') {
		print " [$master_mac]"
	    }
            print ", Master Priority: $master_prio\n";
	}
        print "  Sync-group: $sync\n" if defined $sync;
    } else {
	print "Physical interface $intf, State: unknown\n";
    }
    my $elapsed = elapse_time($start_time, $now_time);
    print "  Last transition: $elapsed\n\n";
    if ($state eq "backup") {

    }
}

#
# main
#    
my @intfs = ("eth", "bond");
my $group = "all";
my $showsummary = 0;

if ($#ARGV >= 0) {
    if ($ARGV[0] eq "summary") {
        $showsummary = 1;
    } else {
        @intfs = ($ARGV[0]);
    }
}

if ($#ARGV == 1) {
    $group = $ARGV[1];
}

if (!Vyatta::Keepalived::is_running()) {
    print "VRRP isn't running\n";
    exit 1;
}

my $display_func;
if ($showsummary == 1) {
    $display_func = \&vrrp_showsummary;
    my $format = '%-16s%-8s%-8s%-16s%-10s%-9s%-13s%s';
    printf($format, '', 'VRRP', 'Addr', '', 'Interface','Address', 'VRRP', "\n");
    printf($format, 'Interface', 'Group', 'Type', 'Address', 'State','Owner', 'State', 
	   "\n");
    printf($format, '-' x 9, '-' x 5, '-' x 4 , '-' x 7, '-' x 5, '-' x 5, '-' x 5, '', );
} else {
    $display_func = \&vrrp_show;
}

foreach my $intf (@intfs) {
    my $intf_vrid;
    if ($intf =~ m/(\w+)\.(\d+)v(\d+)/){
       $intf = "$1.$2";
       $intf_vrid = $3; 
    } elsif ($intf =~ m/(\w+)v(\d+)/){
       $intf = $1;
       $intf_vrid = $2; 
    }
    next if ($group ne 'all' && $intf_vrid && $intf_vrid != $group);
    $group = $intf_vrid if ($group eq 'all' && $intf_vrid);
    my @state_files = Vyatta::Keepalived::get_state_files($intf, $group);
    foreach my $state_file (@state_files) {
	&$display_func($state_file);
    }
}

exit 0;

#end of file
