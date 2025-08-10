import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart'; // Import Provider
import '../providers/map_state.dart'; // Import MapState

class TimeScreen extends StatelessWidget {
  // No constructor args needed
  const TimeScreen({super.key});


  // Function to show date and time pickers
  Future<void> _selectDateTime(BuildContext context, DateTime currentSelectedTime) async {
    // Pick Date
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: currentSelectedTime,
      firstDate: DateTime(2020), // Allow past dates
      lastDate: DateTime.now().add(const Duration(days: 730)), // Allow future dates (2 years)
    );

    if (pickedDate == null || !context.mounted) return; // Check context after await

    // Pick Time
    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(currentSelectedTime),
    );

    if (pickedTime == null || !context.mounted) return; // Check context after await

    // Combine date and time
    final combined = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    // Update state via provider
    Provider.of<MapState>(context, listen: false).setSelectedTime(combined);
  }

  // Function to set time to now
  void _setCurrentTime(BuildContext context) {
    Provider.of<MapState>(context, listen: false).setSelectedTime(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    // Get current selected time from provider to display and use as initial picker value
    final mapState = context.watch<MapState>();
    final selectedDateTime = mapState.selectedDateTime;

    return Scaffold(
      appBar: AppBar(title: const Text("Select Time")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Selected Time:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              // Format date and time clearly
              DateFormat('EEEE, dd MMM yyyy').format(selectedDateTime),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              DateFormat('HH:mm').format(selectedDateTime),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 30),

            // Button to change date/time
            ElevatedButton.icon(
              onPressed: () => _selectDateTime(context, selectedDateTime),
              icon: const Icon(Icons.edit_calendar),
              label: const Text("Change Date & Time"),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
            ),

            const SizedBox(height: 15),

            // Button to reset to current time
            TextButton.icon(
              onPressed: () => _setCurrentTime(context),
              icon: const Icon(Icons.update), // Use a relevant icon
              label: const Text("Use Current Time"),
            ),
          ],
        ),
      ),
    );
  }
}