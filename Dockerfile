FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY OpenSearchEventProducer.sln ./
COPY OpenSearchEventProducer/OpenSearchEventProducer.csproj OpenSearchEventProducer/
RUN dotnet restore OpenSearchEventProducer/OpenSearchEventProducer.csproj

COPY OpenSearchEventProducer/ OpenSearchEventProducer/
RUN dotnet publish OpenSearchEventProducer/OpenSearchEventProducer.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS runtime
WORKDIR /app

COPY --from=build /app/publish .

ENTRYPOINT ["dotnet", "OpenSearchEventProducer.dll"]
