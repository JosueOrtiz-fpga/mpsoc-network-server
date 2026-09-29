# PL Temp Sensor Test log
```
amd-edf:~$ i2cdetect -l
i2c-0	unknown   	Cadence I2C at ff030000         	N/A
i2c-1	unknown   	xiic-i2c b0000000.i2c           	N/A
amd-edf:~$ sudo i2cdetect -y -r 1
     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
00:                         -- -- -- -- -- -- -- -- 
10: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
20: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
30: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 3f 
40: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
50: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
60: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
70: -- -- -- -- -- -- -- --                         
amd-edf:~$ sudo i2cget -y 1 0x3F 0x01
0xa0
amd-edf:~$ A=0x3F
amd-edf:~$ sudo i2cset -y 1 $A 0x0C 0x02
amd-edf:~$ sudo i2cset -y 1 $A 0x0C 0x00
amd-edf:~$ sudo i2cset -y 1 $A 0x04 0x01  
 to clear$ for i in 1 2 3 4 5 6 7 8 9 10; do      # wait for BUSY (STATUS bit 0) 
>   s=$(sudo i2cget -y 1 $A 0x05); [ $(( s & 1 )) -eq 0 ] && break; sleep 0.05
> done
amd-edf:~$ raw=$(( (H << 8) | L )); [ $raw -ge 32768 ] && raw=$(( raw - 65536 ))
amd-edf:~$ awk -v r=$raw 'BEGIN{printf "raw=%d  temp=%.2f C\n", r, r/100}'
raw=3409  temp=34.09 C
amd-edf:~$ 
```









```