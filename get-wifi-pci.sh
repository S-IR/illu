sudo modprobe vfio-pci;
echo vfio-pci | sudo tee /sys/bus/pci/devices/0000:07:00.0/driver_override;
  echo 0000:07:00.0 | sudo tee /sys/bus/pci/devices/0000:07:00.0/driver/unbind;

echo 0000:07:00.0 | sudo tee /sys/bus/pci/drivers_probe;

lspci -nnk -s 07:00.0;
