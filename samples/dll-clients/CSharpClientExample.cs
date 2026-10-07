// CSharpClientExample.cs
//
// Calls PineLib (built with either Delphi or Free Pascal - see
// demo/PineLib.dpr) from C# via P/Invoke.
//
// Build & run with the .NET SDK:
//   dotnet run CSharpClientExample.cs
// or compile directly:
//   csc CSharpClientExample.cs
//
// Put PineLib.dll (Windows) or libPineLib.so (Linux, with the .so loader
// able to find it - e.g. next to the executable, or on LD_LIBRARY_PATH)
// alongside the built program.

using System;
using System.Runtime.InteropServices;
using System.Text;

internal static class PineLib
{
    // .NET's loader already tries "PineLib" -> "PineLib.dll" on Windows
    // and "libPineLib.so" on Linux on its own, so one name covers both.
    private const string LibraryName = "PineLib";

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr PineRunJson(byte[] script, byte[] candlesJson, byte[] settingsJson);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void PineFreeString(IntPtr str);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr PineVersion();

    // UTF-8 bytes with an explicit trailing \0 - exactly the C-string
    // shape the library expects. A plain `string` parameter would also
    // work with [MarshalAs(UnmanagedType.LPUTF8Str)] on .NET Core 3+/.NET
    // 5+, but the byte[] form here works on .NET Framework too.
    private static byte[] ToUtf8CString(string s)
    {
        byte[] encoded = Encoding.UTF8.GetBytes(s ?? string.Empty);
        byte[] withNul = new byte[encoded.Length + 1];
        Array.Copy(encoded, withNul, encoded.Length);
        return withNul;
    }

    // Copies the UTF-8 C string the library returned into a .NET string,
    // then releases the library's own copy via PineFreeString. Never pass
    // a pointer PineRunJson/PineVersion returned to Marshal.FreeHGlobal or
    // any other allocator - only PineFreeString owns it.
    private static string Consume(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero)
        {
            return string.Empty;
        }
        int length = 0;
        while (Marshal.ReadByte(ptr, length) != 0)
        {
            length++;
        }
        byte[] buffer = new byte[length];
        Marshal.Copy(ptr, buffer, 0, length);
        PineFreeString(ptr);
        return Encoding.UTF8.GetString(buffer);
    }

    public static string Version() => Consume(PineVersion());

    public static string Run(string script, string candlesJson = "", string settingsJson = "")
        => Consume(PineRunJson(ToUtf8CString(script), ToUtf8CString(candlesJson), ToUtf8CString(settingsJson)));
}

internal static class Program
{
    private static void Main()
    {
        Console.WriteLine("Library version: " + PineLib.Version());
        Console.WriteLine();

        string script =
            "//@version=5\n" +
            "indicator(\"C# client example\")\n" +
            "plot(close, \"Close\")\n" +
            "plot(ta.sma(close, 10), \"SMA 10\")\n";
        string settings = "{\"syntheticBars\": 30, \"pretty\": true}";

        string resultJson = PineLib.Run(script, "[]", settings);
        Console.WriteLine("Result JSON:");
        Console.WriteLine(resultJson);
    }
}
