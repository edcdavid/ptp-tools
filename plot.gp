# Set the terminal to PNG for output image
set terminal png size 8000,600

# Set the output file name
set output 'plot.png'

# Set the x-axis as time
set xdata time
set timefmt "%Y-%m-%dT%H:%M:%S"
set format x "%H:%M:%S"

# Label the axes
set xlabel "Time"
set ylabel "Time (nanoseconds)"
set ytics -300,10
set grid ytics

# Set title
set title "Timestamp vs Offset"
set datafile separator ","
#set xrange ["2025-02-17T04:21:59.455566842":"2025-02-17T04:23:00.144075634+00:00"]

# Plot the CSV file with line style, skipping values equal to 1000 and displaying "timeout" label
plot 'offset.csv' using 1:($2 == 40.1111 ? 1/0 : $2) with lines title "Offset", \
     '' using 1:2:(strcol(2) eq "40.1111" ? "timeout" : "") with labels offset 1,1 title "Timeout"