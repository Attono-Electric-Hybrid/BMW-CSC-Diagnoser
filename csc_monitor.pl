#!/usr/bin/perl

use strict;
use warnings;
use Curses;
use Redis;
use Time::HiRes qw(sleep);
use List::Util qw(sum);

# Define color pair numbers for clarity
use constant {
    PAIR_DEFAULT          => 0,
    PAIR_ALERT_CRITICAL   => 1, # White on Red
    PAIR_TEMP_OK          => 2, # White on Blue
    PAIR_ALERT_WARN_TEMP  => 3, # Black on Yellow
};

# --- Curses Initialization ---
initscr();
noecho();
curs_set(0);
nodelay(1);

# --- Color and Layout Setup ---
if (has_colors()) {
    start_color();
    init_pair(PAIR_ALERT_CRITICAL,  COLOR_WHITE, COLOR_RED);
    init_pair(PAIR_TEMP_OK,         COLOR_WHITE, COLOR_BLUE);
    init_pair(PAIR_ALERT_WARN_TEMP, COLOR_BLACK, COLOR_YELLOW);
}

my ($max_y, $max_x) = (LINES, COLS);
if ($max_y < 15 || $max_x < 132) {
    endwin();
    die "Terminal is too small. Minimum size is 132x15.\n";
}

# --- Redis Connection ---
my $redis = Redis->new or die_gracefully("Could not connect to Redis server.");

# --- Main Application Loop ---
my $is_held = 0;
my %display_data;
my $stats = { total => 0, corrupt => 0 };
my $median_temp = 0;

while (1) {
    # 1. Check for user input
    my $key = getch();
    if (defined $key) {
        last if ($key eq 'q');
        if ($key eq 'h') {
            $is_held = !$is_held;
        }
    }

    # 2. Fetch new data only if display is NOT held
    if (!$is_held) {
        my @csc_temp_keys = sort($redis->keys('bms:csc_temps:*'));
        
        my @all_temps;
        %display_data = ();

        # Aggregate all data
        foreach my $key (@csc_temp_keys) {
            my ($csc_num) = $key =~ /bms:csc_temps:(\d+)/;
            next unless $csc_num;
            
            $display_data{$csc_num}{voltages} = { $redis->hgetall("bms:csc:$csc_num") };
            my $temps = { $redis->hgetall($key) };
            $display_data{$csc_num}{temps} = $temps;
            push @all_temps, values %{$temps};
        }
        
        # Calculate median temperature from the global sample
        if (scalar @all_temps >= 5) {
            my @sorted_temps = sort { $a <=> $b } @all_temps;
            $median_temp = $sorted_temps[int(@sorted_temps / 2)];
        } else {
            $median_temp = 0; # Not enough data for a meaningful median
        }

        # Fetch message statistics
        $stats = {
            total   => $redis->get('bms:stats:total_messages') || 0,
            corrupt => $redis->get('bms:stats:corrupted_frames') || 0,
        };
    }
    
    # 3. Draw the screen
    draw_screen(\%display_data, $is_held, $stats, $median_temp, $max_x, $max_y);
    
    # 4. Wait
    sleep(1);
}

# --- Cleanup ---
endwin();
exit 0;

# --- Subroutines ---

sub draw_screen {
    my ($data_ref, $is_held, $msg_stats, $median_temp, $max_x, $max_y) = @_;
    erase();

    # --- Header & Footer ---
    my $time_str = localtime();
    addstr(0, 0, "BMW CSC Monitor");
    addstr(0, $max_x - length($time_str), $time_str);
    addstr($max_y - 1, 0, "Press 'q' to quit, 'h' to hold/un-hold.");
    if ($is_held) {
        attron(A_REVERSE);
        addstr($max_y - 1, 40, " [DISPLAY HELD] ");
        attroff(A_REVERSE);
    }
    
    # --- Table Headers ---
    addstr(2, 10, "  1     2     3     4     5     6     7     8     9    10    11    12    13    14    15    16   | Near   Mid    Far ");
    addstr(3, 10, "----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- ----- -----  | ----   ----   ----");

    # --- Table Body ---
    for my $csc_num (sort {$a <=> $b} keys %{$data_ref}) {
        my $y_pos = $csc_num + 3;
        addstr($y_pos, 0, "CSC $csc_num:");

        my $voltages_ref = $data_ref->{$csc_num}{voltages} || {};
        my $temps_ref    = $data_ref->{$csc_num}{temps}    || {};
        
        # ... (Voltage display logic unchanged) ...
        for my $cell_num (1..16) {
             my $x_pos = 10 + (($cell_num - 1) * 6);
            my $v_val = $voltages_ref->{$cell_num};
            my $v_str = defined($v_val) ? sprintf("%4.2f", $v_val) : "....";
            
            if (defined($v_val) && ($v_val > 4.2 || $v_val < 3.0)) {
                attron(COLOR_PAIR(PAIR_ALERT_CRITICAL));
            }
            addstr($y_pos, $x_pos, $v_str);
            attroff(COLOR_PAIR(PAIR_ALERT_CRITICAL));
        }

        # Display Temperatures with median deviation highlighting
        addstr($y_pos, 107, "|");
        my @sensors = ({ num => 1, x => 109 }, { num => 3, x => 116 }, { num => 2, x => 122 });

        foreach my $sensor (@sensors) {
            my $t_val = $temps_ref->{$sensor->{num}};
            my $t_str = defined($t_val) ? sprintf("%4.1f", $t_val) : "....";
            
            my $color_pair = PAIR_DEFAULT;
            if (defined($t_val)) {
                my $deviation = $median_temp > 0 ? abs($t_val - $median_temp) : 0;

                if ($t_val < 0 || $t_val > 50 || ($median_temp > 0 && $deviation > 4)) {
                    $color_pair = PAIR_ALERT_CRITICAL;
                } elsif ($median_temp > 0 && $deviation > 2) {
                    $color_pair = PAIR_ALERT_WARN_TEMP;
                } else {
                    $color_pair = PAIR_TEMP_OK;
                }
            }
            
            attron(COLOR_PAIR($color_pair));
            addstr($y_pos, $sensor->{x}, $t_str);
            attroff(COLOR_PAIR($color_pair));
        }
    }
    
    # --- Statistics Display ---
    my $corruption_rate = ($msg_stats->{total} > 0) ? ($msg_stats->{corrupt} / $msg_stats->{total}) * 100 : 0;
    my $stats_y_pos = 11;

    addstr($stats_y_pos, 0, "--- Statistics ---");
    addstr($stats_y_pos + 1, 0, "Total Messages Seen: $msg_stats->{total}");
    addstr($stats_y_pos + 2, 0, "Corrupted Frames:    $msg_stats->{corrupt}");
    addstr($stats_y_pos + 3, 0, "Corruption Rate:     " . sprintf("%.2f%%", $corruption_rate));
    addstr($stats_y_pos + 4, 0, sprintf("Global Temp Median: %.2fC", $median_temp));

    refresh();
}

sub die_gracefully {
    my ($message) = @_;
    endwin();
    die "$message\n";
}
