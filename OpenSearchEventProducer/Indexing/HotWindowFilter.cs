namespace OpenSearchEventProducer.Indexing;

public sealed class HotWindowFilter
{
    public bool IsWithinHotWindow(DateTimeOffset eventTimestamp, DateTimeOffset now, int hotWindowDays)
    {
        if (hotWindowDays < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(hotWindowDays), "Hot window must be at least 1 day.");
        }

        var eventDate = eventTimestamp.UtcDateTime.Date;
        var today = now.UtcDateTime.Date;
        var oldestAllowedDate = today.AddDays(-(hotWindowDays - 1));

        return eventDate >= oldestAllowedDate && eventDate <= today;
    }
}
