page 50101 "ETL Distances API"
{
    PageType = API;
    APIPublisher = 'etlpipeline';
    APIGroup = 'warehouse';
    APIVersion = 'v1.0';
    EntityName = 'etlDistance';
    EntitySetName = 'etlDistances';
    SourceTable = "ETL Distance";
    DelayedInsert = true;
    ODataKeyFields = "Origin", "Destination";

    layout
    {
        area(Content)
        {
            repeater(GroupName)
            {
                field(origin; Rec."Origin") { Caption = 'origin'; }
                field(destination; Rec."Destination") { Caption = 'destination'; }
                field(distanceKm; Rec."Distance Km") { Caption = 'distanceKm'; }
                field(durationMin; Rec."Duration Min") { Caption = 'durationMin'; }
                field(etlLoadedAt; Rec."ETL Loaded At") { Caption = 'etlLoadedAt'; }
            }
        }
    }
}
