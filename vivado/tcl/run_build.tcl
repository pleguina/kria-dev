# run_build.tcl -- open project built by build_bd.tcl, synth + impl + bitstream + XSA
# Run:  vivado -mode batch -source tcl/build_bd.tcl -source tcl/run_build.tcl   (cwd = vivado/)
# (build_bd.tcl leaves the project open)

set ORIGIN [file normalize [file dirname [info script]]/..]
set PROJ   kv260_imx477
set BD     camctl
set JOBS   8
set OUT    $ORIGIN/out
file mkdir $OUT

set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]

puts ">>> synthesis"
reset_run synth_1
launch_runs synth_1 -jobs $JOBS
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synthesis did not finish"
    exit 1
}
open_run synth_1 -name synth_1
report_utilization -file $OUT/util_synth.rpt
puts ">>> synthesis OK"

puts ">>> implementation + bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs $JOBS
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: impl did not finish"
    exit 1
}
open_run impl_1
report_timing_summary -file $OUT/timing.rpt
set wns [get_property STATS.WNS [get_runs impl_1]]
puts ">>> impl done.  WNS = $wns"

set impl $ORIGIN/build/$PROJ/$PROJ.runs/impl_1
file copy -force $impl/${BD}_wrapper.bit $OUT/kv260_imx477.bit
write_hw_platform -fixed -include_bit -force $OUT/kv260_imx477.xsa
write_debug_probes -force $OUT/kv260_imx477.ltx  ;# harmless if no ILA

puts ">>> outputs in $OUT :"
foreach f [glob -nocomplain $OUT/*] { puts "     $f" }
puts "=== run_build.tcl complete  (WNS=$wns) ==="
