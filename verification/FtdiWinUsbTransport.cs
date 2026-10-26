using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

// Configure and transmit only on FT2232H channel B, never channel A (JTAG).
// Probe reads descriptors; UART control requests are sent only by Open().
public sealed class FtdiWinUsbTransport : IDisposable
{
    private SafeFileHandle file;
    private IntPtr primary, uart;
    private byte readPipe, writePipe;
    private ushort packetSize;
    private readonly Queue<byte> received = new Queue<byte>();
    public string DevicePath { get; private set; }

    [StructLayout(LayoutKind.Sequential)]
    private struct InterfaceData
    {
        public int Size;
        public Guid Guid;
        public int Flags;
        public IntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct InterfaceDescriptor
    {
        public byte Length, DescriptorType, Number, Alternate, Endpoints;
        public byte Class, SubClass, Protocol, StringIndex;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct PipeInfo
    {
        public int Type;
        public byte Id;
        public ushort MaxPacketSize;
        public byte Interval;
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct SetupPacket
    {
        public byte Type, Request;
        public ushort Value, Index, Length;
    }
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid guid, string enumerator, IntPtr parent, uint flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr list, IntPtr device, ref Guid guid, uint index, ref InterfaceData data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr list, ref InterfaceData data, IntPtr detail, uint size, out uint required, IntPtr device);
    [DllImport("setupapi.dll")]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_Initialize(SafeFileHandle device, out IntPtr handle);
    [DllImport("winusb.dll")]
    private static extern bool WinUsb_Free(IntPtr handle);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_GetAssociatedInterface(IntPtr handle, byte index, out IntPtr associated);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_QueryInterfaceSettings(IntPtr handle, byte alternate, out InterfaceDescriptor descriptor);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_QueryPipe(IntPtr handle, byte alternate, byte index, out PipeInfo info);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_GetDescriptor(IntPtr handle, byte type, byte index, ushort language, byte[] buffer, uint length, out uint transferred);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_SetPipePolicy(IntPtr handle, byte pipe, uint policy, uint size, ref uint value);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_ControlTransfer(IntPtr handle, SetupPacket setup, byte[] buffer, uint length, out uint transferred, IntPtr overlapped);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_WritePipe(IntPtr handle, byte pipe, byte[] buffer, uint length, out uint transferred, IntPtr overlapped);
    [DllImport("winusb.dll", SetLastError = true)]
    private static extern bool WinUsb_ReadPipe(IntPtr handle, byte pipe, byte[] buffer, uint length, out uint transferred, IntPtr overlapped);

    private static void Check(bool success, string operation)
    {
        if (!success)
        {
            int error = Marshal.GetLastWin32Error();
            throw new Win32Exception(error, operation + " (Win32 " + error + ": " + new Win32Exception(error).Message + ")");
        }
    }

    private static string[] FindPaths(string serialNumber)
    {
        // The first two GUIDs are advertised by the installed board WinUSB
        // driver. Also support the standard USB device interface GUID.
        string[] guids = { "ea5b3b6d-c64f-4d17-bcf0-02014eb6074b", "dee824ef-729b-4a0e-9c14-b7117d33a817", "a5dcbf10-6530-11d2-901f-00c04fb951ed" };
        List<string> found = new List<string>();
        foreach (string name in guids)
        {
            Guid guid = new Guid(name);
            IntPtr list = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 0x12);
            if (list == new IntPtr(-1)) continue;
            try
            {
                for (uint index = 0; ; index++)
                {
                    InterfaceData data = new InterfaceData();
                    data.Size = Marshal.SizeOf(typeof(InterfaceData));
                    if (!SetupDiEnumDeviceInterfaces(list, IntPtr.Zero, ref guid, index, ref data))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 259) break;
                        throw new Win32Exception(error, "Enumerate board USB interfaces");
                    }
                    uint required;
                    SetupDiGetDeviceInterfaceDetail(list, ref data, IntPtr.Zero, 0, out required, IntPtr.Zero);
                    IntPtr detail = Marshal.AllocHGlobal((int)required);
                    try
                    {
                        Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                        Check(SetupDiGetDeviceInterfaceDetail(list, ref data, detail, required, out required, IntPtr.Zero), "Read USB device path");
                        string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                        if (path.IndexOf("vid_0403&pid_6042", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        string[] parts = path.Split('#');
                        if (parts.Length < 3) continue;
                        if (!String.IsNullOrEmpty(serialNumber) && !String.Equals(parts[2], serialNumber, StringComparison.OrdinalIgnoreCase)) continue;
                        bool duplicate = false;
                        foreach (string old in found)
                            if (String.Equals(old.Split('#')[2], parts[2], StringComparison.OrdinalIgnoreCase) &&
                                String.Equals(old.Split('#')[1], parts[1], StringComparison.OrdinalIgnoreCase)) duplicate = true;
                        if (!duplicate) found.Add(path);
                    }
                    finally { Marshal.FreeHGlobal(detail); }
                }
            }
            finally { SetupDiDestroyDeviceInfoList(list); }
        }
        return found.ToArray();
    }

    private FtdiWinUsbTransport(string path)
    {
        DevicePath = path;
        try
        {
            file = CreateFile(path, 0xc0000000, 3, IntPtr.Zero, 3, 0x40000080, IntPtr.Zero);
            Check(!file.IsInvalid, "Open board WinUSB device; close TD download/debug and stop any remaining TD hwserver.exe if busy");
            Check(WinUsb_Initialize(file, out primary), "Initialize existing board WinUSB driver");
            byte[] descriptor = new byte[18];
            uint length;
            Check(WinUsb_GetDescriptor(primary, 1, 0, 0, descriptor, 18, out length), "Read FT2232H identity");
            if (length != 18 || BitConverter.ToUInt16(descriptor, 8) != 0x0403 ||
                BitConverter.ToUInt16(descriptor, 10) != 0x6042 || BitConverter.ToUInt16(descriptor, 12) != 0x0700)
                throw new IOException("Expected the board FT2232H (0403:6042, bcdDevice=0700).");
            InterfaceDescriptor setting;
            Check(WinUsb_QueryInterfaceSettings(primary, 0, out setting), "Read primary USB interface");
            if (setting.Number == 1) uart = primary;
            else
            {
                Check(WinUsb_GetAssociatedInterface(primary, 0, out uart), "Access associated UART channel B using the existing WinUSB driver");
                Check(WinUsb_QueryInterfaceSettings(uart, 0, out setting), "Read UART channel B interface");
            }
            if (setting.Number != 1) throw new IOException("UART channel B (interface 1) is unavailable; channel A will not be used.");
            for (byte i = 0; i < setting.Endpoints; i++)
            {
                PipeInfo pipe;
                Check(WinUsb_QueryPipe(uart, 0, i, out pipe), "Read UART channel B endpoints");
                if (pipe.Type != 2) continue;
                if (pipe.Id == 0x83) { readPipe = pipe.Id; packetSize = pipe.MaxPacketSize; }
                if (pipe.Id == 0x04) writePipe = pipe.Id;
            }
            if (readPipe == 0 || writePipe == 0 || packetSize < 3)
                throw new IOException("Expected FT2232H B endpoints OUT=04 IN=83; refusing to access other endpoints.");
        }
        catch { Dispose(); throw; }
    }

    private static FtdiWinUsbTransport Connect(string serialNumber)
    {
        string[] paths = FindPaths(serialNumber);
        if (paths.Length == 0) throw new IOException("No board WinUSB interface found for 0403:6042. Connect the board and keep its WinUSB driver.");
        if (paths.Length != 1) throw new IOException("More than one matching USB interface found. Specify -UsbSerial to select the board; separate interface bindings may require the COM transport.");
        return new FtdiWinUsbTransport(paths[0]);
    }

    public static string Probe(string serialNumber)
    {
        using (FtdiWinUsbTransport device = Connect(serialNumber))
            return "RESNET18_WINUSB_PROBE_OK vid=0403 pid=6042 interface=1 out=04 in=83 packet_size=" + device.packetSize + " descriptor_only=true";
    }

    public static FtdiWinUsbTransport Open(string serialNumber, int baud)
    {
        if (baud != 921600) throw new ArgumentException("The current FPGA bitstream requires 921600 baud.");
        FtdiWinUsbTransport device = Connect(serialNumber);
        try
        {
            uint timeout = 1000;
            Check(WinUsb_SetPipePolicy(device.uart, device.readPipe, 3, 4, ref timeout), "Set UART USB read timeout");
            timeout = 5000;
            Check(WinUsb_SetPipePolicy(device.uart, device.writePipe, 3, 4, ref timeout), "Set UART USB write timeout");
            // Every FTDI request is explicitly indexed to B (2). Do not use
            // SIO_RESET_SIO or device resets, which could disturb JTAG.
            device.Control(11, 0, 2);       // B: UART mode, disable MPSSE.
            device.Control(2, 0, 2);        // B: no flow control.
            device.Control(4, 8, 2);        // B: 8 data bits, no parity, 1 stop.
            device.Control(3, 13, 0x0202);  // 120 MHz / 10 / 13 = 923076.9 baud.
            device.Control(9, 1, 2);        // B: 1 ms latency timer.
            device.Control(0, 1, 2);        // B: purge RX only.
            device.Control(0, 2, 2);        // B: purge TX only.
            return device;
        }
        catch { device.Dispose(); throw; }
    }

    private void Control(byte request, ushort value, ushort index)
    {
        SetupPacket setup = new SetupPacket();
        setup.Type = 0x40; setup.Request = request; setup.Value = value; setup.Index = index;
        uint transferred;
        Check(WinUsb_ControlTransfer(primary, setup, new byte[0], 0, out transferred, IntPtr.Zero), "Configure FT2232H UART B request " + request);
    }

    public void Write(byte[] data, int offset, int count)
    {
        byte[] payload = data;
        if (offset != 0 || count != data.Length)
        {
            payload = new byte[count];
            Array.Copy(data, offset, payload, 0, count);
        }
        uint written;
        Check(WinUsb_WritePipe(uart, writePipe, payload, (uint)count, out written, IntPtr.Zero), "Write UART B payload");
        if (written != count) throw new IOException("Incomplete UART USB write.");
    }

    public int ReadByte()
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        while (received.Count == 0)
        {
            if (elapsed.ElapsedMilliseconds >= 5000) throw new TimeoutException("No FPGA UART acknowledgement within 5 seconds.");
            byte[] data = new byte[packetSize];
            uint read;
            if (!WinUsb_ReadPipe(uart, readPipe, data, (uint)data.Length, out read, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == 121) continue; // USB pipe timeout.
                throw new Win32Exception(error, "Read UART B acknowledgement");
            }
            // Each FTDI USB packet starts with two modem/line status bytes.
            // The one-packet read size prevents a status header from ever
            // becoming a protocol ACK or NAK.
            if (read >= 2 && (data[1] & 0x1e) != 0)
                throw new IOException("FTDI UART B reported overrun/parity/framing/break error: " + data[1].ToString("X2"));
            for (int i = 2; i < read; i++) received.Enqueue(data[i]);
        }
        return received.Dequeue();
    }

    public void Dispose()
    {
        if (uart != IntPtr.Zero && uart != primary) WinUsb_Free(uart);
        uart = IntPtr.Zero;
        if (primary != IntPtr.Zero) WinUsb_Free(primary);
        primary = IntPtr.Zero;
        if (file != null) { file.Dispose(); file = null; }
    }
}
