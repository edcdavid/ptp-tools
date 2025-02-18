# Building local images 
To build all images (ptp-operator, linuxptp-daemon, kube-rbac-proxy, cloud-event-proxy) to a single personal repository, run the command below.
The command uses a single quay.io repository ans stores the different images as tags:
- `cep` tag: cloud-event-proxy
- `ptpop` tag: ptp-operator
- `lptpd` tag: linuxptp-daemon
- `krp` tag: kube-rbac-proxy  
```
IMG_PREFIX=quay.io/<user>/<repo> make podman-build-all
```

To push all images:
```
IMG_PREFIX=quay.io/<user>/<repo> make podman-push-all
```

To deploy all containers including cloud-event-proxy sidecar:
```
IMG_PREFIX=quay.io/<user>/<repo> make deploy-all
```

# Build NVidia Bluefield 3 helper tools container for Openshift platform

Verify that the kernel version of openshift matches the kernel version in the [Dockerfile.tools](Dockerfile.tools). Currently the kernel is hardcoded to 5.14.0-427.50.1.el9_4.aarch64.

Build the image:
```
IMG_PREFIX=quay.io/<user>/<repo> make podman-build-tools
```

Push the quay.io/<user>/<repo>:tools image to your repository:
```
IMG_PREFIX=quay.io/<user>/<repo> make podman-push-tools
```

# Configure NVidia Bluefield 3 with Hardware timestamps

To use the image created above, ssh to the node containing the Bluefield 3 card and run the following with podman:
```
podman run --rm -d --privileged --name tools --net=host --pull=always quay.io/<user>/<repo>:tools
```

# To plot long term ptp4l offset graphs with gnuplot

Run the following command on the cluster running openshift-ptp
```
oc adm must-gather
```

Retrieve the logs corresponding to the linux-ptp-daemon logs
```
must-gather.local.6257239071106258211/
└── quay-io-openshift-release-dev-ocp-v4-0-art-dev-sha256-72ed7cee7798f64a4c30788fd3ef055046357cf95c29bf796be9e39369475141
    └── namespaces
        └── openshift-ptp
            └── pods
                └── linuxptp-daemon-6kmjr
                    └── linuxptp-daemon-container
                        └── linuxptp-daemon-container
                            └── logs
                                ├── current.log
                                ├── previous.insecure.log
                                ├── previous.log
                                └── rotated
                                    ├── 0.log.20250217-072641.gz
                                    ├── 0.log.20250217-103132.gz
                                    ├── 0.log.20250217-133614.gz
                                    └── 0.log.20250217-164056
```

The logs in the "rotated subdirectory are compressed except for the more recent one". 
Unpack all logs with:
```
cd rotated
gzip -d *
```

Concatenate all logs in a single file:
```
cat 0.log.*  | sort -k1,1 > alllogs.txt 
```

Create a csv file with timestamps and offset value:
```
./scripts/getoffset.sh alllogs.txt offset.csv 
```

Edit the ./scripts/plot.gp file to use the offset.csv input csv, then render the graph:
```
gnuplot plot.gp
```

Output graph should be similar to:
![graph example](plot.png)

# Nvidia Bluefield 3 DPU

## Overview
The bluefield 3 card (bf3) is a data processing unit (DPU) connecting to the host system via a PCI bus similarly to a NIC. The DPU has a programmable openvswitch hardware, a CPU and 32G of RAM. It can offload switching in hardware instead of using software openvswitch in openshift. It can also run full workload, including AI on its GPU.
The DPU can work in NIC or DPU mode, In NIC mode it is currently not supported to offload processing of PTP frames.
The main documentation link is at https://docs.nvidia.com/networking/dpu-doca/index.html#doca 
![BF3 overview](doc/bluefield3.svg)

## Build a BF3 helper container image
To help with debugging and configuring the DPU, the following container is provided [Dockerfile.tools](Dockerfile.tools).

Build the quay.io/<user>/<repo>:tools image using 
```
IMG_PREFIX=quay.io/<user>/<repo> make podman-build-tools        
```
then push it to your repo with:
```
IMG_PREFIX=quay.io/<user>/<repo> make podman-push-tools   
```
## Run the BF3 tools image on openshift host
Then ssh to the node where the BF3 DPU is installed and run the following:
*Note:* do not use --net=host as the service in the container will rename the host interfaces and kill the host network.
```
podman run --rm -d --privileged --name tools  quay.io/<user>/<repo>:tools
```

Execute into the container with 
```
podman exec -ti tools bash
```

Start the rshim service with:
```
systemctl start rshim
```

After starting the service, the following interfaces will appear:
```
[root@3c62018acd7c /]# ip a
...
3: tmfifo_net0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN group default qlen 1000
    link/ether 00:1a:ca:ff:ff:02 brd ff:ff:ff:ff:ff:ff
    inet6 fe80::21a:caff:feff:ff02/64 scope link 
       valid_lft forever preferred_lft forever
4: tmfifo_net1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN group default qlen 1000
    link/ether 00:1a:ca:ff:ff:04 brd ff:ff:ff:ff:ff:ff
    inet6 fe80::21a:caff:feff:ff04/64 scope link 
       valid_lft forever preferred_lft forever
```

Each interface corresponds to a BF3 card. The interfaces are used to ssh to the card embedded server and perfom configuration and maintenance operations such as upgrades, manual configuration, debugging, etc.

Assign an ip address to the interface:
```
  ip addr add dev tmfifo_net0 192.168.100.1/30
```
## Connect to the DPU host
The remote interface on this net is the BF3 card at the 192.168.100.2 address. ssh to the bf3 embedded server with:
```
ssh ubuntu@192.168.100.2
```
The default password is ubuntu and will needs to be changed on th first connection with ssh.
After the password is changed, the connection drops and you can try login again with the new password.
```
ubuntu@localhost:~$
```
Ubuntu is the default distribution but it can be customized, just as any server. The Linux software running on BF3 is packaged into NVidia BSP packages

By default, 2 openvswitch bridges are configured, one per external port:
```
ubuntu@localhost:~$ sudo ovs-vsctl list-br
ovsbr1
ovsbr2
```

The default configuration should look like this:
```
ubuntu@localhost:~$ sudo ovs-ofctl dump-flows ovsbr1
 cookie=0x0, duration=27390.565s, table=0, n_packets=0, n_bytes=0, priority=0 actions=NORMAL
```

## Configure Hardware timestamps for PTP in BF3 DPU
In DPU mode, the documentation gives the example of configuring PTP to intercept L3 PTP IP frames in order to record a timestamp see (https://docs.nvidia.com/doca/sdk/doca+firefly+service+guide/index.html#src-3499060042_id-.DOCAFireflyServiceGuidev2.10.0-supportTXtimestamping).
To work with linuxptp-daemon, we need a different configuration in order to intercept L2 PTP Ethernet frames based on the PTP Ethertype (0x88F7). 
The openvswitch rules below assume that the default `ovsbr1` bridge is present.
```
 sudo ovs-ofctl add-flow ovsbr1 "in_port=pf0hpf,dl_type=0x88F7,actions=output:p0"
 sudo ovs-ofctl add-flow ovsbr1 "in_port=p0,dl_type=0x88F7,actions=output:pf0hpf"
```
`pf0hpf` represents the external port 0 of the BF3 card. `pf1hpf` would be the second port, port 1.
`p0` represent the first port exposed by the BF3 card to the host, `p1`, is the second port. These 2 ports correspond to the external interfaces, physical function ports. The card can also create virtual functions as part of sriov. So the rule above forward ptp frames from the external port to the internal host port via the offloading engine which will add a timestamp.

The updated flows are then:
```
ubuntu@localhost:~$ sudo ovs-ofctl dump-flows ovsbr1
 cookie=0x0, duration=2689.653s, table=0, n_packets=42577, n_bytes=2554548, in_port=pf0hpf,dl_type=0x88f7 actions=output:p0
 cookie=0x0, duration=2689.627s, table=0, n_packets=107155, n_bytes=7157314, in_port=p0,dl_type=0x88f7 actions=output:pf0hpf
 cookie=0x0, duration=27393.302s, table=0, n_packets=1435340, n_bytes=76025574, priority=0 actions=NORMAL
```

For the HW timestamp, we need to enable HW offloading and timestamps. This is achieved with the `mstconfig` function

You can identify the correct interface to configure based on mac address on the openshift host(not in the container). The interfaces appear on the openshift host as:
```
5: enP2s2f0np0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 5c:25:73:6d:95:18 brd ff:ff:ff:ff:ff:ff
    altname enP2p1s0f0np0
    inet6 fe80::1a64:f26b:c605:e53e/64 scope link noprefixroute 
       valid_lft forever preferred_lft forever
```

Get the pci address of the interface that you have identified based on  mac address, under `bus-info`:
```
[root@cnfdg45 ~]# ethtool -i enP2s2f0np0
driver: mlx5_core
version: 5.14.0-427.50.1.el9_4.aarch64
firmware-version: 32.43.1014 (MT_0000000884)
expansion-rom-version: 
bus-info: 0002:01:00.0
supports-statistics: yes
supports-test: yes
supports-eeprom-access: no
supports-register-dump: no
supports-priv-flags: yes
[root@cnfdg45 ~]# 
```

In this case the pci address is `0002:01:00.0`

Go back in the container to have access to the Bluefield tools:
```
 podman exec -ti tools bash
```
and run `mstconfig -d 0002:01:00.0 q` to view the full firmware configuration:
```
[root@3c62018acd7c /]# mstconfig -d 0002:01:00.0 q

Device #1:
----------

Device type:    BlueField3      
Name:           900-9D3B6-00CV-A_Ax
Description:    NVIDIA BlueField-3 B3220 P-Series FHHL DPU; 200GbE (default mode) / NDR200 IB; Dual-port QSFP112; PCIe Gen5.0 x16 with x16 PCIe extension option; 16 Arm cores; 32GB on-board DDR; integrated BMC; Crypto Enabled
Device:         0002:01:00.0    

Configurations:                                      Next Boot
        MODULE_SPLIT_M0                             Array[0..15]    
        MODULE_SPLIT_M1                             Array[0..15]    
        MEMIC_BAR_SIZE                              0               
        MEMIC_SIZE_LIMIT                            _256KB(1)       
        MEMIC_ATOMIC                                MEMIC_ATOMIC_ENABLE(2)
        HOST_CHAINING_MODE                          DISABLED(0)     
        HOST_CHAINING_CACHE_DISABLE                 False(0)        
        HOST_CHAINING_DESCRIPTORS                   Array[0..7]     
        HOST_CHAINING_TOTAL_BUFFER_SIZE             Array[0..7]     
        INTERNAL_CPU_MODEL                          EMBEDDED_CPU(1) 
        INTERNAL_CPU_PAGE_SUPPLIER                  ECPF(0)         
        INTERNAL_CPU_ESWITCH_MANAGER                ECPF(0)         
        INTERNAL_CPU_IB_VPORT0                      ECPF(0)         
        INTERNAL_CPU_OFFLOAD_ENGINE                 ENABLED(0)      
        FLEX_PARSER_PROFILE_ENABLE                  0               
        PROG_PARSE_GRAPH                            False(0)        
        FLEX_IPV4_OVER_VXLAN_PORT                   0               
        ROCE_NEXT_PROTOCOL                          254             
        ESWITCH_HAIRPIN_DESCRIPTORS                 Array[0..7]     
        ESWITCH_HAIRPIN_TOT_BUFFER_SIZE             Array[0..7]     
        DPA_AUTHENTICATION                          False(0)        
        PF_BAR2_SIZE                                3               
        INTERNAL_CPU_RSHIM                          ENABLED(0)      
        PF_NUM_OF_VF_VALID                          False(0)        
        NON_PREFETCHABLE_PF_BAR                     False(0)        
        VF_VPD_ENABLE                               False(0)        
        PF_NUM_PF_MSIX_VALID                        False(0)        
        PER_PF_NUM_SF                               False(0)        
        STRICT_VF_MSIX_NUM                          False(0)        
        VF_NODNIC_ENABLE                            False(0)        
        NUM_PF_MSIX_VALID                           True(1)         
        NUM_OF_VFS                                  16              
        NUM_OF_PF                                   2               
        PF_BAR2_ENABLE                              True(1)         
        HIDE_PORT2_PF                               False(0)        
        SRIOV_EN                                    True(1)         
        PF_LOG_BAR_SIZE                             5               
        VF_LOG_BAR_SIZE                             1               
        NUM_PF_MSIX                                 63              
        NUM_VF_MSIX                                 11              
        INT_LOG_MAX_PAYLOAD_SIZE                    AUTOMATIC(0)    
        PCIE_CREDIT_TOKEN_TIMEOUT                   0               
        RT_PPS_ENABLED_ON_POWERUP                   False(0)        
        LAG_RESOURCE_ALLOCATION                     DEVICE_DEFAULT(0)
        ACCURATE_TX_SCHEDULER                       False(0)        
        PARTIAL_RESET_EN                            False(0)        
        RESET_WITH_HOST_ON_ERRORS                   False(0)        
        NVME_EMULATION_ENABLE                       False(0)        
        NVME_EMULATION_NUM_VF                       0               
        NVME_EMULATION_NUM_PF                       1               
        NVME_EMULATION_VENDOR_ID                    5555            
        NVME_EMULATION_DEVICE_ID                    24577           
        NVME_EMULATION_CLASS_CODE                   67586           
        NVME_EMULATION_REVISION_ID                  0               
        NVME_EMULATION_SUBSYSTEM_VENDOR_ID          0               
        NVME_EMULATION_SUBSYSTEM_ID                 0               
        NVME_EMULATION_NUM_MSIX                     0               
        NVME_EMULATION_MAX_QUEUE_DEPTH              0               
        PCI_SWITCH_EMULATION_NUM_PORT               16              
        PCI_SWITCH_EMULATION_ENABLE                 False(0)        
        VIRTIO_NET_EMULATION_ENABLE                 False(0)        
        VIRTIO_NET_EMULATION_NUM_VF                 0               
        VIRTIO_NET_EMULATION_NUM_PF                 0               
        VIRTIO_NET_EMU_SUBSYSTEM_VENDOR_ID          6900            
        VIRTIO_NET_EMULATION_SUBSYSTEM_ID           4161            
        VIRTIO_NET_EMULATION_NUM_MSIX               2               
        VIRTIO_BLK_EMULATION_ENABLE                 False(0)        
        VIRTIO_BLK_EMULATION_NUM_VF                 0               
        VIRTIO_BLK_EMULATION_NUM_PF                 0               
        VIRTIO_BLK_EMU_SUBSYSTEM_VENDOR_ID          6900            
        VIRTIO_BLK_EMULATION_SUBSYSTEM_ID           4162            
        VIRTIO_BLK_EMULATION_NUM_MSIX               2               
        PCI_DOWNSTREAM_PORT_OWNER                   Array[0..15]    
        VIRTIO_FS_EMULATION_ENABLE                  False(0)        
        VIRTIO_FS_EMULATION_NUM_VF                  0               
        VIRTIO_FS_EMULATION_NUM_PF                  0               
        VIRTIO_FS_EMU_SUBSYSTEM_VENDOR_ID           6900            
        VIRTIO_FS_EMULATION_SUBSYSTEM_ID            4186            
        VIRTIO_FS_EMULATION_NUM_MSIX                2               
        STRAP_PEX_CORES                             PEX_1_CORE(0)   
        STRAP_PCIE_SWITCHES                         0               
        STRAP_SECONDARY_PCORE_HOSTS1                HOST_1(0)       
        STRAP_SD_OR_MH                              False(0)        
        STRAP_DUAL_PCORE                            False(0)        
        STRAP_SECONDARY_PCORE_REVERSAL              False(0)        
        STRAP_ASYMMETRIC_PCORE                      False(0)        
        PCI_BUS01_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS01_SWITCH_INDEX                      0               
        PCI_BUS01_SPEED                             PCI_GEN_1(0)    
        PCI_BUS01_ASPM                              False(0)        
        PCI_BUS01_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS00_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS00_SWITCH_INDEX                      0               
        PCI_BUS00_SPEED                             PCI_GEN_1(0)    
        PCI_BUS00_ASPM                              False(0)        
        PCI_BUS00_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS03_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS03_SWITCH_INDEX                      0               
        PCI_BUS03_SPEED                             PCI_GEN_1(0)    
        PCI_BUS03_ASPM                              False(0)        
        PCI_BUS03_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS02_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS02_SWITCH_INDEX                      0               
        PCI_BUS02_SPEED                             PCI_GEN_1(0)    
        PCI_BUS02_ASPM                              False(0)        
        PCI_BUS02_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS05_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS05_SWITCH_INDEX                      0               
        PCI_BUS05_SPEED                             PCI_GEN_1(0)    
        PCI_BUS05_ASPM                              False(0)        
        PCI_BUS05_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS04_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS04_SWITCH_INDEX                      0               
        PCI_BUS04_SPEED                             PCI_GEN_1(0)    
        PCI_BUS04_ASPM                              False(0)        
        PCI_BUS04_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS07_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS07_SWITCH_INDEX                      0               
        PCI_BUS07_SPEED                             PCI_GEN_1(0)    
        PCI_BUS07_ASPM                              False(0)        
        PCI_BUS07_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS06_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS06_SWITCH_INDEX                      0               
        PCI_BUS06_SPEED                             PCI_GEN_1(0)    
        PCI_BUS06_ASPM                              False(0)        
        PCI_BUS06_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS11_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS11_SWITCH_INDEX                      0               
        PCI_BUS11_SPEED                             PCI_GEN_1(0)    
        PCI_BUS11_ASPM                              False(0)        
        PCI_BUS11_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS10_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS10_SWITCH_INDEX                      0               
        PCI_BUS10_SPEED                             PCI_GEN_1(0)    
        PCI_BUS10_ASPM                              False(0)        
        PCI_BUS10_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS13_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS13_SWITCH_INDEX                      0               
        PCI_BUS13_SPEED                             PCI_GEN_1(0)    
        PCI_BUS13_ASPM                              False(0)        
        PCI_BUS13_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS12_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS12_SWITCH_INDEX                      0               
        PCI_BUS12_SPEED                             PCI_GEN_1(0)    
        PCI_BUS12_ASPM                              False(0)        
        PCI_BUS12_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS15_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS15_SWITCH_INDEX                      0               
        PCI_BUS15_SPEED                             PCI_GEN_1(0)    
        PCI_BUS15_ASPM                              False(0)        
        PCI_BUS15_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS14_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS14_SWITCH_INDEX                      0               
        PCI_BUS14_SPEED                             PCI_GEN_1(0)    
        PCI_BUS14_ASPM                              False(0)        
        PCI_BUS14_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS17_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS17_SWITCH_INDEX                      0               
        PCI_BUS17_SPEED                             PCI_GEN_1(0)    
        PCI_BUS17_ASPM                              False(0)        
        PCI_BUS17_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS16_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS16_SWITCH_INDEX                      0               
        PCI_BUS16_SPEED                             PCI_GEN_1(0)    
        PCI_BUS16_ASPM                              False(0)        
        PCI_BUS16_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS21_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS21_SWITCH_INDEX                      0               
        PCI_BUS21_SPEED                             PCI_GEN_1(0)    
        PCI_BUS21_ASPM                              False(0)        
        PCI_BUS21_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS20_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS20_SWITCH_INDEX                      0               
        PCI_BUS20_SPEED                             PCI_GEN_1(0)    
        PCI_BUS20_ASPM                              False(0)        
        PCI_BUS20_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS23_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS23_SWITCH_INDEX                      0               
        PCI_BUS23_SPEED                             PCI_GEN_1(0)    
        PCI_BUS23_ASPM                              False(0)        
        PCI_BUS23_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS22_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS22_SWITCH_INDEX                      0               
        PCI_BUS22_SPEED                             PCI_GEN_1(0)    
        PCI_BUS22_ASPM                              False(0)        
        PCI_BUS22_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS25_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS25_SWITCH_INDEX                      0               
        PCI_BUS25_SPEED                             PCI_GEN_1(0)    
        PCI_BUS25_ASPM                              False(0)        
        PCI_BUS25_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS24_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS24_SWITCH_INDEX                      0               
        PCI_BUS24_SPEED                             PCI_GEN_1(0)    
        PCI_BUS24_ASPM                              False(0)        
        PCI_BUS24_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS27_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS27_SWITCH_INDEX                      0               
        PCI_BUS27_SPEED                             PCI_GEN_1(0)    
        PCI_BUS27_ASPM                              False(0)        
        PCI_BUS27_WIDTH                             PCI_INACTIVE(0) 
        PCI_BUS26_HIERARCHY_TYPE                    PCIE_ENDPOINT(0)
        PCI_BUS26_SWITCH_INDEX                      0               
        PCI_BUS26_SPEED                             PCI_GEN_1(0)    
        PCI_BUS26_ASPM                              False(0)        
        PCI_BUS26_WIDTH                             PCI_INACTIVE(0) 
        PCI_SWITCH1_UPSTRAEM_PORT_PEX               0               
        PCI_SWITCH1_UPSTRAEM_PORT_BUS               0               
        PCI_SWITCH0_UPSTRAEM_PORT_PEX               0               
        PCI_SWITCH0_UPSTRAEM_PORT_BUS               0               
        PCI_SWITCH2_UPSTRAEM_PORT_PEX               0               
        PCI_SWITCH2_UPSTRAEM_PORT_BUS               0               
        GPIO_CPLD_ENABLE                            0               
        GPIO_WAKE0_NUMBER                           0               
        GPIO_WAKE0_ENABLE                           False(0)        
        GPIO_PERST1_NUMBER                          0               
        GPIO_PERST1_ENABLE                          False(0)        
        GPIO_WAKE1_NUMBER                           0               
        GPIO_WAKE1_ENABLE                           False(0)        
        GPIO_PERST2_NUMBER                          0               
        GPIO_PERST2_ENABLE                          False(0)        
        GPIO_WAKE2_NUMBER                           0               
        GPIO_WAKE2_ENABLE                           False(0)        
        GPIO_PERST3_NUMBER                          0               
        GPIO_PERST3_ENABLE                          False(0)        
        GPIO_WAKE3_NUMBER                           0               
        GPIO_WAKE3_ENABLE                           False(0)        
        GPIO_PERST4_NUMBER                          0               
        GPIO_PERST4_ENABLE                          False(0)        
        GPIO_WAKE4_NUMBER                           0               
        GPIO_WAKE4_ENABLE                           False(0)        
        GPIO_PERST5_NUMBER                          0               
        GPIO_PERST5_ENABLE                          False(0)        
        GPIO_WAKE5_NUMBER                           0               
        GPIO_WAKE5_ENABLE                           False(0)        
        GPIO_PERST6_NUMBER                          0               
        GPIO_PERST6_ENABLE                          False(0)        
        GPIO_WAKE6_NUMBER                           0               
        GPIO_WAKE6_ENABLE                           False(0)        
        GPIO_PERST7_NUMBER                          0               
        GPIO_PERST7_ENABLE                          False(0)        
        GPIO_WAKE7_NUMBER                           0               
        GPIO_WAKE7_ENABLE                           False(0)        
        CQE_COMPRESSION                             BALANCED(0)     
        IP_OVER_VXLAN_EN                            False(0)        
        MKEY_BY_NAME                                False(0)        
        PRIO_TAG_REQUIRED_EN                        False(0)        
        UCTX_EN                                     True(1)         
        REAL_TIME_CLOCK_ENABLE                      True(1)         
        RDMA_SELECTIVE_REPEAT_EN                    False(0)        
        PCI_ATOMIC_MODE                             PCI_ATOMIC_DISABLED_EXT_ATOMIC_ENABLED(0)
        TUNNEL_ECN_COPY_DISABLE                     False(0)        
        LRO_LOG_TIMEOUT0                            6               
        LRO_LOG_TIMEOUT1                            7               
        LRO_LOG_TIMEOUT2                            8               
        LRO_LOG_TIMEOUT3                            13              
        LOG_TX_PSN_WINDOW                           9               
        VF_MIGRATION_MODE                           DEVICE_DEFAULT(0)
        LOG_MAX_OUTSTANDING_WQE                     7               
        ROCE_ADAPTIVE_ROUTING_EN                    False(0)        
        TUNNEL_IP_PROTO_ENTROPY_DISABLE             False(0)        
        USER_PROGRAMMABLE_CC                        False(0)        
        PCC_HANDLE_CORE_UTIL                        DEVICE_DEFAULT(0)
        PCC_INT_NP_RTT_DSCP                         26              
        PCC_INT_NP_RTT_DSCP_EN                      False(0)        
        PCC_INT_NP_RTT_DATA_MODE                    RTT_V0(64)      
        PCC_INT_EN                                  False(0)        
        PCC_INT_SYSTEM_RTT                          0               
        STEERING_CACHE_REFRESH                      0               
        ICM_CACHE_MODE                              DEVICE_DEFAULT(0)
        HAIRPIN_DATA_BUFFER_LOCK                    False(0)        
        TX_SCHEDULER_BURST                          0               
        ZERO_TOUCH_TUNING_ENABLE                    False(0)        
        LOG_MAX_QUEUE                               17              
        UPT_EMULATION_ENABLE                        False(0)        
        AES_XTS_TWEAK_INC_64                        False(0)        
        CRYPTO_POLICY                               UNRESTRICTED(1) 
        RDE_DISABLE                                 False(0)        
        PLDM_FW_UPDATE_DISABLE                      False(0)        
        RBT_DISABLE                                 False(0)        
        PCIE_SMBUS_DISABLE                          False(0)        
        PCIE_IN_BAND_VDM_DISABLE                    False(0)        
        LOG_DCR_HASH_TABLE_SIZE                     11              
        MAX_PACKET_LIFETIME                         0               
        DCR_LIFO_SIZE                               16384           
        LINK_TYPE_P1                                ETH(2)          
        LINK_TYPE_P2                                ETH(2)          
        ROCE_CC_PRIO_MASK_P1                        255             
        ROCE_CC_SHAPER_COALESCE_P1                  DEVICE_DEFAULT(0)
        IB_CC_SHAPER_COALESCE_P1                    DEVICE_DEFAULT(0)
        ROCE_CC_PRIO_MASK_P2                        255             
        ROCE_CC_SHAPER_COALESCE_P2                  DEVICE_DEFAULT(0)
        IB_CC_SHAPER_COALESCE_P2                    DEVICE_DEFAULT(0)
        CLAMP_TGT_RATE_AFTER_TIME_INC_P1            True(1)         
        CLAMP_TGT_RATE_P1                           False(0)        
        RPG_TIME_RESET_P1                           300             
        RPG_BYTE_RESET_P1                           32767           
        RPG_THRESHOLD_P1                            1               
        RPG_MAX_RATE_P1                             0               
        RPG_AI_RATE_P1                              5               
        RPG_HAI_RATE_P1                             50              
        RPG_GD_P1                                   11              
        RPG_MIN_DEC_FAC_P1                          50              
        RPG_MIN_RATE_P1                             1               
        RATE_TO_SET_ON_FIRST_CNP_P1                 0               
        DCE_TCP_G_P1                                1019            
        DCE_TCP_RTT_P1                              1               
        RATE_REDUCE_MONITOR_PERIOD_P1               4               
        INITIAL_ALPHA_VALUE_P1                      1023            
        MIN_TIME_BETWEEN_CNPS_P1                    4               
        CNP_802P_PRIO_P1                            6               
        CNP_DSCP_P1                                 48              
        CLAMP_TGT_RATE_AFTER_TIME_INC_P2            True(1)         
        CLAMP_TGT_RATE_P2                           False(0)        
        RPG_TIME_RESET_P2                           300             
        RPG_BYTE_RESET_P2                           32767           
        RPG_THRESHOLD_P2                            1               
        RPG_MAX_RATE_P2                             0               
        RPG_AI_RATE_P2                              5               
        RPG_HAI_RATE_P2                             50              
        RPG_GD_P2                                   11              
        RPG_MIN_DEC_FAC_P2                          50              
        RPG_MIN_RATE_P2                             1               
        RATE_TO_SET_ON_FIRST_CNP_P2                 0               
        DCE_TCP_G_P2                                1019            
        DCE_TCP_RTT_P2                              1               
        RATE_REDUCE_MONITOR_PERIOD_P2               4               
        INITIAL_ALPHA_VALUE_P2                      1023            
        MIN_TIME_BETWEEN_CNPS_P2                    4               
        CNP_802P_PRIO_P2                            6               
        CNP_DSCP_P2                                 48              
        LLDP_NB_DCBX_P1                             False(0)        
        LLDP_NB_RX_MODE_P1                          OFF(0)          
        LLDP_NB_TX_MODE_P1                          OFF(0)          
        LLDP_NB_DCBX_P2                             False(0)        
        LLDP_NB_RX_MODE_P2                          OFF(0)          
        LLDP_NB_TX_MODE_P2                          OFF(0)          
        ROCE_RTT_RESP_DSCP_P1                       0               
        ROCE_RTT_RESP_DSCP_MODE_P1                  DEVICE_DEFAULT(0)
        ROCE_RTT_RESP_DSCP_P2                       0               
        ROCE_RTT_RESP_DSCP_MODE_P2                  DEVICE_DEFAULT(0)
        DCBX_IEEE_P1                                True(1)         
        DCBX_CEE_P1                                 True(1)         
        DCBX_WILLING_P1                             True(1)         
        DCBX_IEEE_P2                                True(1)         
        DCBX_CEE_P2                                 True(1)         
        DCBX_WILLING_P2                             True(1)         
        KEEP_ETH_LINK_UP_P1                         True(1)         
        KEEP_IB_LINK_UP_P1                          False(0)        
        KEEP_LINK_UP_ON_BOOT_P1                     False(0)        
        KEEP_LINK_UP_ON_STANDBY_P1                  False(0)        
        DO_NOT_CLEAR_PORT_STATS_P1                  False(0)        
        AUTO_POWER_SAVE_LINK_DOWN_P1                False(0)        
        KEEP_ETH_LINK_UP_P2                         True(1)         
        KEEP_IB_LINK_UP_P2                          False(0)        
        KEEP_LINK_UP_ON_BOOT_P2                     False(0)        
        KEEP_LINK_UP_ON_STANDBY_P2                  False(0)        
        DO_NOT_CLEAR_PORT_STATS_P2                  False(0)        
        AUTO_POWER_SAVE_LINK_DOWN_P2                False(0)        
        NUM_OF_VL_P1                                _4_VLs(3)       
        NUM_OF_TC_P1                                _8_TCs(0)       
        NUM_OF_PFC_P1                               8               
        VL15_BUFFER_SIZE_P1                         0               
        QOS_TRUST_STATE_P1                          TRUST_PCP(1)    
        NUM_OF_VL_P2                                _4_VLs(3)       
        NUM_OF_TC_P2                                _8_TCs(0)       
        NUM_OF_PFC_P2                               8               
        VL15_BUFFER_SIZE_P2                         0               
        QOS_TRUST_STATE_P2                          TRUST_PCP(1)    
        DUP_MAC_ACTION_P1                           LAST_CFG(0)     
        MPFS_MC_LOOPBACK_DISABLE_P1                 False(0)        
        MPFS_UC_LOOPBACK_DISABLE_P1                 False(0)        
        UNKNOWN_UPLINK_MAC_FLOOD_P1                 False(0)        
        SRIOV_IB_ROUTING_MODE_P1                    LID(1)          
        IB_ROUTING_MODE_P1                          LID(1)          
        DUP_MAC_ACTION_P2                           LAST_CFG(0)     
        MPFS_MC_LOOPBACK_DISABLE_P2                 False(0)        
        MPFS_UC_LOOPBACK_DISABLE_P2                 False(0)        
        UNKNOWN_UPLINK_MAC_FLOOD_P2                 False(0)        
        SRIOV_IB_ROUTING_MODE_P2                    LID(1)          
        IB_ROUTING_MODE_P2                          LID(1)          
        PHY_AUTO_NEG_P1                             DEVICE_DEFAULT(0)
        PHY_RATE_MASK_OVERRIDE_P1                   False(0)        
        PHY_FEC_OVERRIDE_P1                         DEVICE_DEFAULT(0)
        PHY_AUTO_NEG_P2                             DEVICE_DEFAULT(0)
        PHY_RATE_MASK_OVERRIDE_P2                   False(0)        
        PHY_FEC_OVERRIDE_P2                         DEVICE_DEFAULT(0)
        PF_TOTAL_SF                                 0               
        PF_SF_BAR_SIZE                              0               
        PF_NUM_PF_MSIX                              63              
        SILENT_MODE                                 False(0)        
        MKEY_BY_NAME_RANGE                          DEVICE_DEFAULT(0)
        ROCE_CONTROL                                ROCE_ENABLE(2)  
        PCI_WR_ORDERING                             per_mkey(0)     
        MULTI_PORT_VHCA_EN                          False(0)        
        PORT_OWNER                                  True(1)         
        ALLOW_RD_COUNTERS                           True(1)         
        RENEG_ON_CHANGE                             True(1)         
        TRACER_ENABLE                               True(1)         
        IP_VER                                      IPv4(0)         
        BOOT_UNDI_NETWORK_WAIT                      0               
        UEFI_HII_EN                                 True(1)         
        BOOT_DBG_LOG                                False(0)        
        UEFI_LOGS                                   DISABLED(0)     
        BOOT_VLAN                                   1               
        LEGACY_BOOT_PROTOCOL                        PXE(1)          
        BOOT_INTERRUPT_DIS                          False(0)        
        BOOT_LACP_DIS                               True(1)         
        BOOT_VLAN_EN                                False(0)        
        BOOT_PKEY                                   0               
        P2P_ORDERING_MODE                           DEVICE_DEFAULT(0)
        EXP_ROM_VIRTIO_NET_PXE_ENABLE               True(1)         
        EXP_ROM_VIRTIO_NET_UEFI_ARM_ENABLE          True(1)         
        EXP_ROM_VIRTIO_NET_UEFI_x86_ENABLE          True(1)         
        EXP_ROM_VIRTIO_BLK_UEFI_ARM_ENABLE          True(1)         
        EXP_ROM_VIRTIO_BLK_UEFI_x86_ENABLE          True(1)         
        EXP_ROM_NVME_UEFI_x86_ENABLE                True(1)         
        ATS_ENABLED                                 False(0)        
        DYNAMIC_VF_MSIX_TABLE                       False(0)        
        EXP_ROM_UEFI_ARM_ENABLE                     True(1)         
        EXP_ROM_UEFI_x86_ENABLE                     True(1)         
        EXP_ROM_PXE_ENABLE                          True(1)         
        ADVANCED_PCI_SETTINGS                       False(0)        
        SAFE_MODE_THRESHOLD                         10              
        SAFE_MODE_ENABLE                            True(1)         
```

To enable Hardware timestamps and the HW offload engine, configure the following parameters:
```
mstconfig -d 0002:01:00.0 set REAL_TIME_CLOCK_ENABLE=1 INTERNAL_CPU_OFFLOAD_ENGINE=1
```

You must reboot the host openshift server to apply the changes (not in the container):
```
reboot
```

When the server is up again turn on the TX timestamp private flag on the openshift host with ethtool:
```
ethtool --set-priv-flags enP2s2f0np0 tx_port_ts on
```

After this point, the enP2s2f0np0 should be ready for ptp configuration.