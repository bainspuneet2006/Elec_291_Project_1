@echo off
::This file was created automatically by CrossIDE to load a hex file using Quartus_stp.
"C:\intelFPGA_lite\24.1std\quartus\bin64\quartus_stp.exe" -t "C:\CrossIDE\Load_Script.tcl" "C:\elec291\Elec_291_Project_1\Assembly_Code\DE10Lite\jodhan_testing_full.HEX" | find /v "Warning (113007)"
